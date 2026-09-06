import Foundation
import Observation
import UCIKit
#if canImport(DanceChessCore)
import DanceChessCore
#endif

/// One annotation the whole-game analysis wants to make, applied by
/// `GameSession.applyAnalysis` in a single undo step.
struct AnalysisMark {
    let node: UInt32
    /// $6 (?!), $2 (?) or $4 (??); nil = the move only gets a comment.
    let nag: UInt8?
    /// Appended to the move's existing comment ("+0.35 → −1.20").
    let comment: String?
    /// The engine's line from the position before the move, as a variation
    /// beside it. Empty when the played move was the engine's choice.
    let bestLine: [String]
    /// Written on the last move of `bestLine` (the line's own eval).
    let lineComment: String?
}

struct AnalysisSettings {
    var depth = 18
    /// Centipawn loss thresholds, mover's perspective.
    var inaccuracy = 50
    var mistake = 100
    var blunder = 300
    /// Plies of the engine line to insert for a mistake or blunder.
    var lineLength = 6
}

/// ChessBase's "Full Analysis" in its useful core: walk the main line with
/// a fixed-depth search, and where a move loses more than a threshold,
/// mark it (?! ? ??), say what the eval did, and put the engine's line
/// beside it. Runs its own Stockfish so the live panel is not disturbed;
/// nothing touches the game until the end, when every mark lands at once
/// under one undo step. Cancel discards everything.
@Observable
@MainActor
final class GameAnalyzer {
    private(set) var running = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var currentLabel = ""
    private(set) var errorText: String?
    /// Filled when a run completes (not when cancelled).
    private(set) var summary: String?

    private var engine: UCIEngine?
    private var cancelled = false

    private struct Eval {
        let whiteCp: Int       // mate mapped to ±10_000
        let text: String       // "+0.35", "#3", "#−2"
        let pv: [String]       // UCI moves
    }

    func cancel() {
        cancelled = true
        engine?.stop()
    }

    /// Analyzes `session`'s main line and applies the marks. Returns the
    /// number of moves annotated, or nil if cancelled / failed.
    @discardableResult
    func run(session: GameSession, settings: AnalysisSettings) async -> Int? {
        guard !running else { return nil }
        running = true
        cancelled = false
        errorText = nil
        summary = nil
        defer { running = false }

        guard let url = EngineSession.findStockfish() else {
            errorText = "Stockfish not found"
            return nil
        }
        let engine = UCIEngine(executable: url)
        self.engine = engine
        defer { engine.quit(); self.engine = nil }
        do {
            try await engine.start()
            engine.setOption("Threads",
                             String(max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
            engine.setOption("Hash", "256")
            try await engine.isReady()
        } catch {
            errorText = "Engine failed to start: \(error)"
            return nil
        }

        // the path root → last mainline move; the root is analyzed too,
        // since it is the "before" of move 1
        var path = session.game.mainline()
        if path.first != 0 { path.insert(0, at: 0) }
        guard path.count > 1 else { errorText = "Nothing to analyze"; return nil }
        total = path.count
        done = 0

        var evals: [Eval] = []
        var fens: [String] = []
        var stoppedAt: String?
        for id in path {
            if cancelled { return nil }
            let fen: String
            do {
                fen = try session.game.fenAt(id: id)
            } catch {
                // an imported game can carry an illegal move (the parser
                // keeps SAN text as written); analyze up to it and say so
                stoppedAt = Self.label(session.game.node(id: id))
                break
            }
            fens.append(fen)
            currentLabel = id == 0 ? "start" : Self.label(session.game.node(id: id))
            // a mating move ends the game: the engine has no score for the
            // position after it (a bare "mate 0" carries no pv and is
            // dropped by the reader), and 0.00 there would mark the mate
            // itself as a blunder. The SAN says what happened.
            if id != 0, session.game.node(id: id).san.hasSuffix("#") {
                let whiteMated = session.game.node(id: id).isWhiteMove
                evals.append(Eval(whiteCp: whiteMated ? 10_000 : -10_000, text: "#", pv: []))
                done += 1
                continue
            }
            do {
                evals.append(try await evaluate(engine: engine, fen: fen, depth: settings.depth))
            } catch {
                if !cancelled { errorText = "Analysis interrupted: \(error)" }
                return nil
            }
            done += 1
        }
        if cancelled { return nil }
        guard evals.count > 1 else {
            errorText = "The game's first move is illegal (\(stoppedAt ?? "?"))"
            return nil
        }

        var marks: [AnalysisMark] = []
        for k in 0..<(evals.count - 1) {
            let before = evals[k], after = evals[k + 1]
            let node = path[k + 1]
            let info = session.game.node(id: node)
            let sign = info.isWhiteMove ? 1 : -1
            let moverBefore = sign * before.whiteCp
            let loss = sign * (before.whiteCp - after.whiteCp)
            // a position already lost by more than a queen: every move
            // "loses" and marking them all says nothing
            guard moverBefore > -900 else { continue }
            let nag: UInt8?
            switch loss {
            case settings.blunder...: nag = 4
            case settings.mistake...: nag = 2
            case settings.inaccuracy...: nag = 6
            default: nag = nil
            }
            guard let nag else { continue }
            // the engine's own choice cannot be a mistake: an eval that
            // still drops after it is the search seeing further one ply
            // later, not the player going wrong — the classic depth
            // artifact, and marking it would put "??" on forced moves
            let bestLine = before.pv.isEmpty ? [] :
                ((try? uciLineToSan(fen: fens[k],
                                    moves: Array(before.pv.prefix(settings.lineLength)))) ?? [])
            guard let best = bestLine.first, Self.bare(best) != Self.bare(info.san) else { continue }
            let line = nag == 6 ? [] : bestLine
            marks.append(AnalysisMark(
                node: node, nag: nag,
                comment: "\(before.text) → \(after.text)",
                bestLine: line,
                lineComment: line.isEmpty ? nil : before.text))
        }
        session.applyAnalysis(marks)
        let analyzed = evals.count - 1
        summary = (marks.isEmpty
            ? "No move lost more than \(settings.inaccuracy) centipawns at depth \(settings.depth)."
            : "\(marks.count) of \(analyzed) moves marked at depth \(settings.depth).")
            + (stoppedAt.map { " Stopped at \($0): illegal move in the game." } ?? "")
        return marks.count
    }

    private func evaluate(engine: UCIEngine, fen: String, depth: Int) async throws -> Eval {
        let whiteToMove = fen.split(separator: " ").dropFirst().first.map { $0 == "w" } ?? true
        var last: UCIInfo?
        _ = try await engine.analyze(fen: fen, depth: depth, multipv: 1) { info in
            if info.multipv == 1 || info.multipv == 0, info.scoreCp != nil || info.scoreMate != nil {
                last = info
            }
        }
        guard let info = last else {
            // no score at all: mate/stalemate on the board — treat as 0
            return Eval(whiteCp: 0, text: "0.00", pv: [])
        }
        if let mate = info.scoreMate {
            let m = whiteToMove ? mate : -mate
            return Eval(whiteCp: m > 0 ? 10_000 : -10_000,
                        text: m > 0 ? "#\(m)" : "#−\(-m)", pv: info.pv)
        }
        let cp = info.scoreCp ?? 0
        let white = whiteToMove ? cp : -cp
        let text = String(format: "%+.2f", Double(white) / 100)
            .replacingOccurrences(of: "-", with: "−")
        return Eval(whiteCp: white, text: text, pv: info.pv)
    }

    /// SAN without check/mate suffix: imported games keep the text as
    /// written, while the engine's line is normalized, so "Nxb5" and
    /// "Nxb5+" must compare equal.
    private static func bare(_ san: String) -> String {
        san.trimmingCharacters(in: CharacterSet(charactersIn: "+#"))
    }

    private static func label(_ n: NodeInfo) -> String {
        "\(n.moveNumber)\(n.isWhiteMove ? "." : "...")\(n.san)"
    }
}
