import Foundation

/// One parsed `info` line from a UCI engine.
public struct UCIInfo: Sendable, Equatable {
    public var depth: Int?
    public var multipv: Int = 1
    /// Centipawns from the side to move's perspective, if not a mate score.
    public var scoreCp: Int?
    /// Moves until mate (negative: engine's side gets mated).
    public var scoreMate: Int?
    public var nodes: Int?
    public var nps: Int?
    /// Principal variation in UCI coordinate notation (e2e4, ...).
    public var pv: [String] = []

    /// Parses a raw engine line; returns nil unless it is an `info` line
    /// carrying a pv (bare "info depth ..." heartbeats are dropped).
    public static func parse(_ line: String) -> UCIInfo? {
        var tokens = line.split(separator: " ")[...]
        guard tokens.first == "info" else { return nil }
        tokens = tokens.dropFirst()
        var info = UCIInfo()
        while let key = tokens.first {
            tokens = tokens.dropFirst()
            switch key {
            case "depth": info.depth = tokens.popInt()
            case "multipv": info.multipv = tokens.popInt() ?? 1
            case "nodes": info.nodes = tokens.popInt()
            case "nps": info.nps = tokens.popInt()
            case "score":
                switch tokens.first {
                case "cp": tokens = tokens.dropFirst(); info.scoreCp = tokens.popInt()
                case "mate": tokens = tokens.dropFirst(); info.scoreMate = tokens.popInt()
                default: break
                }
                // skip "lowerbound"/"upperbound" qualifiers
                while tokens.first == "lowerbound" || tokens.first == "upperbound" {
                    tokens = tokens.dropFirst()
                }
            case "pv":
                info.pv = tokens.map(String.init)
                tokens = tokens.suffix(0)
            default:
                // unknown single-value keys (seldepth, time, hashfull, tbhits...)
                tokens = tokens.dropFirst()
            }
        }
        return info.pv.isEmpty ? nil : info
    }
}

extension ArraySlice where Element == Substring {
    fileprivate mutating func popInt() -> Int? {
        guard let first else { return nil }
        self = dropFirst()
        return Int(first)
    }
}

public struct UCIError: Error, CustomStringConvertible {
    public let description: String
}

/// Manages one UCI engine subprocess. Not thread-safe by design: drive it
/// from a single task (the app wraps it in an actor/@Observable manager).
public final class UCIEngine {
    private let process = Process()
    private let input = Pipe()
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
    public private(set) var name: String = ""

    public init(executable: URL) {
        let output = Pipe()
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
    }

    /// Launches the engine and completes the `uci`/`uciok` handshake.
    public func start() async throws {
        try process.run()
        send("uci")
        while let line = try await lines.next() {
            if line.hasPrefix("id name ") { name = String(line.dropFirst(8)) }
            if line == "uciok" { return }
        }
        throw UCIError(description: "engine exited before uciok")
    }

    public func send(_ command: String) {
        input.fileHandleForWriting.write(Data((command + "\n").utf8))
    }

    public func setOption(_ name: String, _ value: String) {
        send("setoption name \(name) value \(value)")
    }

    /// Waits until the engine confirms it is ready.
    public func isReady() async throws {
        send("isready")
        while let line = try await lines.next() {
            if line == "readyok" { return }
        }
        throw UCIError(description: "engine exited before readyok")
    }

    /// Fixed-depth analysis; streams parsed infos to `onInfo` (one call per
    /// pv update) and returns the best move. The interactive analysis panel
    /// will use `go infinite` + `stop` with the same reading loop.
    public func analyze(
        fen: String,
        depth: Int,
        multipv: Int = 1,
        onInfo: (UCIInfo) -> Void = { _ in }
    ) async throws -> String {
        if multipv != 1 { setOption("MultiPV", String(multipv)) }
        send("position fen \(fen)")
        send("go depth \(depth)")
        while let line = try await lines.next() {
            if let info = UCIInfo.parse(line) {
                onInfo(info)
            } else if line.hasPrefix("bestmove ") {
                return String(line.split(separator: " ")[1])
            }
        }
        throw UCIError(description: "engine exited during analysis")
    }

    public func quit() {
        send("quit")
        // give it a moment, then make sure it is gone
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
            if process.isRunning { process.terminate() }
        }
    }
}
