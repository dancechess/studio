// End-to-end smoke checks for the Swift half, runnable without Xcode:
//   cd app && swift run MacBaseSmoke
// Exercises the Rust bridge (movegen, game tree, notation tokens, database)
// and a real UCI engine if one is installed.
import Foundation
import MacBaseCore
import UCIKit

var failures = 0
func check(_ ok: Bool, _ label: String) {
    print("\(ok ? "ok  " : "FAIL") \(label)")
    if !ok { failures += 1 }
}

let repoRoot = URL(fileURLWithPath: #filePath) // app/Smoke/main.swift
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// --- UCI info parsing (pure Swift) ---
let sample = "info depth 20 seldepth 28 multipv 2 score cp 35 nodes 1500000 nps 900000 time 1667 pv e2e4 e7e5 g1f3"
if let info = UCIInfo.parse(sample) {
    check(info.depth == 20 && info.multipv == 2 && info.scoreCp == 35, "UCIInfo parses depth/multipv/score")
    check(info.pv == ["e2e4", "e7e5", "g1f3"], "UCIInfo parses pv")
} else {
    check(false, "UCIInfo.parse returned nil")
}
check(UCIInfo.parse("info depth 5 currmove e2e4 currmovenumber 1") == nil, "heartbeat info lines dropped")
check(UCIInfo.parse("info depth 3 score mate 2 pv f3f7")?.scoreMate == 2, "mate scores parsed")

// --- Rust bridge: positions ---
let fen = startFen()
check((try? legalMovesSan(fen: fen))?.count == 20, "bridge: 20 legal moves from startpos")

// --- Rust bridge: game tree + notation ---
let pgnPath = repoRoot.appendingPathComponent("fixtures/repertoire_sample.pgn")
let pgn = try String(contentsOf: pgnPath, encoding: .utf8)
let game = try Game.fromPgn(pgn: pgn)
check(game.mainline().count > 10, "bridge: fixture mainline parsed")
let tokens = game.notationTokens()
check(tokens.contains { $0.kind == .paragraphBreak }, "bridge: notation has variation paragraphs")
check(tokens.filter { $0.kind == .move }.allSatisfy { $0.nodeId != nil }, "bridge: every move token clickable")

let scratch = try Game.fromPgn(pgn: "1. e4 e5 2. Qh5 g6 *")
let last = scratch.mainline().last!
let qxe5 = try scratch.addMove(id: last, san: "Qxe5")
check(scratch.node(id: qxe5).san == "Qxe5+", "bridge: SAN check-suffix normalized")

// --- Rust bridge: database + opening tree ---
let dbPath = FileManager.default.temporaryDirectory
    .appendingPathComponent("macbase-smoke-\(ProcessInfo.processInfo.processIdentifier).db")
try? FileManager.default.removeItem(at: dbPath)
let db = try Database.open(path: dbPath.path)
let stats = try db.importPgnFile(path: pgnPath.path)
check(stats.imported >= 1 && stats.skipped == 0, "bridge: fixture imports into SQLite")
let tree = try db.openingTree(fen: startFen())
check(tree.first?.san == "e4", "bridge: opening tree aggregates (top move e4)")
try? FileManager.default.removeItem(at: dbPath)

// --- Rust bridge: engine PV → SAN (drives the analysis panel rows) ---
let pvSans = try uciLineToSan(fen: startFen(), moves: ["e2e4", "e7e5", "g1f3"])
check(pvSans == ["e4", "e5", "Nf3"], "bridge: uci pv converts to SAN")
check(try uciLineToSan(fen: startFen(), moves: ["e2e4", "e2e4"]) == ["e4"],
      "bridge: stale pv tail truncated")

// --- real UCI engine, if installed ---
let stockfish = ["/opt/homebrew/bin/stockfish", "/usr/local/bin/stockfish"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }
if let stockfish {
    let engine = UCIEngine(executable: URL(fileURLWithPath: stockfish))
    try await engine.start()
    check(!engine.name.isEmpty, "uci: handshake (\(engine.name))")
    try await engine.isReady()
    var best: [Int: UCIInfo] = [:]
    let bestMove = try await engine.analyze(fen: startFen(), depth: 12, multipv: 2) {
        best[Int($0.multipv)] = $0
    }
    check(bestMove.count >= 4, "uci: bestmove '\(bestMove)'")
    check(best[1]?.scoreCp != nil || best[1]?.scoreMate != nil, "uci: pv1 has a score")
    check(best[2] != nil, "uci: multipv 2 delivers a second line")

    // infinite analysis (the live panel's mode): stream, stop, terminate
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { engine.stop() }
    var infiniteInfos = 0
    try await engine.analyzeInfinite(fen: startFen(), multipv: 2) { _ in infiniteInfos += 1 }
    check(infiniteInfos > 0, "uci: go infinite streams and stop() ends it")
    engine.quit()
} else {
    print("skip UCI engine checks (no stockfish found)")
}

print(failures == 0 ? "\nALL SMOKE CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
