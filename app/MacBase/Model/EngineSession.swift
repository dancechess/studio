import Foundation
import Observation
import UCIKit
#if canImport(MacBaseCore)
import MacBaseCore
#endif

/// One displayed engine line (PV rank) of the analysis panel.
struct EngineLine: Identifiable, Equatable {
    let id: Int // multipv rank, 1-based
    let depth: Int
    /// Score from White's perspective ("+0.35", "−1.20", "#5", "#−3").
    let scoreText: String
    /// White-perspective centipawns (mate mapped to ±10_000), for the bar.
    let whiteCp: Int
    /// SANs of the PV, for insertion into the game tree.
    let sans: [String]
    /// Display text with move numbers ("12...e5 13.Nf3 Nc6 …").
    let text: String
}

/// Drives one Stockfish subprocess for the live analysis panel: panel
/// visible = engine analyzing the current position (`go infinite`),
/// panel closed = stopped. Position/MultiPV changes interrupt the current
/// search via `stop` and the loop restarts it.
@Observable
@MainActor
final class EngineSession {
    /// The panel is shown (⌘E). Stays true on engine failure so the panel
    /// can display `errorText`.
    private(set) var panelVisible = false
    /// Actually analyzing (engine launched fine and the panel is open).
    private(set) var enabled = false
    private(set) var engineName = ""
    private(set) var lines: [EngineLine] = []
    private(set) var depth = 0
    private(set) var nps = 0
    private(set) var errorText: String?
    /// White-perspective eval of the top line; nil = no data yet.
    var whiteEval: Int? { lines.first?.whiteCp }

    // NB: no didSet with self-reassignment here — under @Observable that
    // recurses infinitely (computed-property wrapper) and crashes.
    private(set) var multiPV = 3

    func setMultiPV(_ value: Int) {
        let clamped = min(max(value, 1), 8)
        guard clamped != multiPV else { return }
        multiPV = clamped
        kick()
    }

    /// No highlighted move yet (game at its root): the engine stays idle —
    /// Stockfish only burns CPU on a position the user actually selected.
    private(set) var awaitingSelection = true

    private var engine: UCIEngine?
    /// Guards against two concurrent setTarget tasks both spawning a
    /// subprocess (the first would leak, unreferenced but running).
    private var startingEngine = false
    /// "" = nothing highlighted → idle.
    private var currentFen = ""
    private var looping = false
    private var generation = 0

    private let debugLog = ProcessInfo.processInfo.environment["MACBASE_ENGINE_DEBUG"] != nil

    /// Bundled engine first (the sandboxed .app can't read /opt/homebrew),
    /// then the usual Homebrew/local paths for bare `swift run`.
    static func findStockfish() -> URL? {
        if let bundled = Bundle.main.url(forResource: "stockfish", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for path in ["/opt/homebrew/bin/stockfish", "/usr/local/bin/stockfish"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// `target` is the highlighted position, nil when no move is selected.
    func togglePanel(target: String?) {
        panelVisible.toggle()
        if panelVisible {
            errorText = nil
            enabled = true
            setTarget(target)
        } else {
            enabled = false
            engine?.stop()
        }
    }

    /// nil = nothing highlighted (game at its root) → engine idles.
    func updatePosition(fen: String?) {
        setTarget(fen)
    }

    /// Stops analysis and tears the subprocess down (window closing).
    func shutdown() {
        enabled = false
        panelVisible = false
        engine?.stop()
        engine?.quit()
        engine = nil
    }

    // MARK: internals

    private func setTarget(_ fen: String?) {
        let target = fen ?? ""
        let changed = target != currentFen
        if debugLog {
            print("engine.setTarget '\(target.prefix(24))' changed=\(changed) enabled=\(enabled) looping=\(looping)")
        }
        currentFen = target
        guard enabled else { return }
        if target.isEmpty {
            awaitingSelection = true
            lines = []
            depth = 0
            nps = 0
            engine?.stop() // running loop drains, then idles at the guard
            return
        }
        awaitingSelection = false
        if looping {
            if changed { engine?.stop() }
        } else {
            // engine subprocess is spawned lazily, on the first real target
            Task {
                await startEngineIfNeeded()
                runLoopIfIdle()
            }
        }
    }

    private func kick() {
        guard enabled, !currentFen.isEmpty else { return }
        if looping { engine?.stop() } else { runLoopIfIdle() }
    }

    private func startEngineIfNeeded() async {
        guard engine == nil, !startingEngine else { return }
        startingEngine = true
        defer { startingEngine = false }
        guard let url = Self.findStockfish() else {
            errorText = "Stockfish not found: brew install stockfish (the packaged app bundles it)"
            return
        }
        if debugLog { print("engine.spawn \(url.path)") }
        let engine = UCIEngine(executable: url)
        do {
            try await engine.start()
            engine.setOption("Threads",
                             String(max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
            engine.setOption("Hash", "256")
            try await engine.isReady()
            self.engine = engine
            engineName = engine.name
        } catch {
            errorText = "Engine failed to start: \(error)"
        }
    }

    private func runLoopIfIdle() {
        guard enabled, !looping, !currentFen.isEmpty, let engine else { return }
        looping = true
        Task { @MainActor in
            defer { looping = false }
            while enabled {
                let fen = currentFen
                guard !fen.isEmpty else { break } // selection cleared: idle
                let mpv = multiPV
                generation += 1
                let gen = generation
                lines = []
                depth = 0
                nps = 0
                let fields = fen.split(separator: " ")
                let whiteToMove = fields.count > 1 ? fields[1] == "w" : true
                let moveNumber = fields.count > 5 ? Int(fields[5]) ?? 1 : 1
                do {
                    try await engine.analyzeInfinite(fen: fen, multipv: mpv) { info in
                        guard self.generation == gen else { return }
                        self.apply(info, fen: fen, whiteToMove: whiteToMove,
                                   moveNumber: moveNumber)
                    }
                } catch {
                    if enabled { errorText = "Analysis interrupted: \(error)" }
                    break
                }
                if !enabled { break }
                // search ended with nothing changed (mate/stalemate):
                // stay idle until the next position/multipv kick
                if fen == currentFen && mpv == multiPV { break }
            }
        }
    }

    private func apply(_ info: UCIInfo, fen: String, whiteToMove: Bool, moveNumber: Int) {
        if info.multipv == 1 {
            if let d = info.depth { depth = d }
            if let n = info.nps { nps = n }
        }
        let whiteCp: Int
        let scoreText: String
        if let mate = info.scoreMate {
            let m = whiteToMove ? mate : -mate
            whiteCp = m > 0 ? 10_000 : -10_000
            scoreText = m > 0 ? "#\(m)" : "#−\(-m)"
        } else {
            let cp = info.scoreCp ?? 0
            whiteCp = whiteToMove ? cp : -cp
            scoreText = String(format: "%+.2f", Double(whiteCp) / 100)
                .replacingOccurrences(of: "-", with: "−")
        }
        let sans = (try? uciLineToSan(fen: fen, moves: Array(info.pv.prefix(16)))) ?? []
        let line = EngineLine(
            id: info.multipv,
            depth: info.depth ?? 0,
            scoreText: scoreText,
            whiteCp: whiteCp,
            sans: sans,
            text: Self.numbered(sans, whiteToMove: whiteToMove, moveNumber: moveNumber)
        )
        if let i = lines.firstIndex(where: { $0.id == line.id }) {
            lines[i] = line
        } else {
            lines.append(line)
            lines.sort { $0.id < $1.id }
        }
    }

    private static func numbered(_ sans: [String], whiteToMove: Bool, moveNumber: Int) -> String {
        var number = moveNumber
        var white = whiteToMove
        var parts: [String] = []
        for (i, san) in sans.enumerated() {
            if white {
                parts.append("\(number).\(san)")
            } else if i == 0 {
                parts.append("\(number)...\(san)")
            } else {
                parts.append(san)
            }
            if !white { number += 1 }
            white.toggle()
        }
        return parts.joined(separator: " ")
    }
}
