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

enum AnalysisSide: String, CaseIterable, Identifiable {
    case both, white, black
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: "Both"
        case .white: "White"
        case .black: "Black"
        }
    }
}

struct AnalysisSettings {
    var depth = 18
    /// Whose moves get marked. A coach looking at a student's game wants
    /// the student's mistakes, not the opponent's.
    var side: AnalysisSide = .both
    /// Every line in the tree, not just the main one.
    var variations = false
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

        // the nodes to look at, parents before children: the main line
        // alone, or every line in the tree. The root is evaluated too —
        // it is the "before" of move 1.
        let game = session.game
        var nodes: [UInt32] = [0]
        if settings.variations {
            var stack: [UInt32] = game.node(id: 0).children.reversed()
            while let n = stack.popLast() {
                nodes.append(n)
                stack.append(contentsOf: game.node(id: n).children.reversed())
            }
        } else {
            nodes.append(contentsOf: game.mainline().filter { $0 != 0 })
        }
        guard nodes.count > 1 else { errorText = "Nothing to analyze"; return nil }
        total = nodes.count
        done = 0

        var evals: [UInt32: Eval] = [:]
        var fens: [UInt32: String] = [:]
        var skipped = 0
        for id in nodes {
            if cancelled { return nil }
            let fen: String
            do {
                fen = try game.fenAt(id: id)
            } catch {
                // an imported game can carry an illegal move (the parser
                // keeps SAN text as written); that line ends here
                skipped += 1
                done += 1
                continue
            }
            fens[id] = fen
            currentLabel = id == 0 ? "start" : Self.label(game.node(id: id))
            // a mating move ends the game: the engine has no score for the
            // position after it (a bare "mate 0" carries no pv and is
            // dropped by the reader), and 0.00 there would mark the mate
            // itself as a blunder. The SAN says what happened.
            if id != 0, game.node(id: id).san.hasSuffix("#") {
                let whiteMated = game.node(id: id).isWhiteMove
                evals[id] = Eval(whiteCp: whiteMated ? 10_000 : -10_000, text: "#", pv: [])
                done += 1
                continue
            }
            do {
                evals[id] = try await evaluate(engine: engine, fen: fen, depth: settings.depth)
            } catch {
                if !cancelled { errorText = "Analysis interrupted: \(error)" }
                return nil
            }
            done += 1
        }
        if cancelled { return nil }
        guard evals.count > 1 else {
            errorText = "The game's first move is illegal"
            return nil
        }

        var marks: [AnalysisMark] = []
        var judged = 0
        for node in nodes where node != 0 {
            let info = game.node(id: node)
            guard let parent = info.parent, let before = evals[parent],
                  let after = evals[node], let parentFen = fens[parent] else { continue }
            switch settings.side {
            case .white where !info.isWhiteMove: continue
            case .black where info.isWhiteMove: continue
            default: break
            }
            judged += 1
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
                ((try? uciLineToSan(fen: parentFen,
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
        let who = settings.side == .both ? "moves" : "\(settings.side.label) moves"
        summary = (marks.isEmpty
            ? "None of \(judged) \(who) lost more than \(settings.inaccuracy) centipawns at depth \(settings.depth)."
            : "\(marks.count) of \(judged) \(who) marked at depth \(settings.depth).")
            + (skipped > 0 ? " \(skipped) position(s) could not be replayed (illegal move in the game)." : "")
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
