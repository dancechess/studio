import CryptoKit
import Foundation
#if canImport(DanceChessCore)
import DanceChessCore
#endif

/// Where the reference panel's statistics come from.
enum ReferenceSource: String, CaseIterable, Identifiable {
    case database, masters, lichess, player
    var id: String { rawValue }
    var label: String {
        switch self {
        case .database: "Database"
        case .masters: "Masters"
        case .lichess: "Lichess"
        case .player: "Player"
        }
    }
}

struct ExplorerResult {
    let rows: [TreeMove]
    let total: UInt32
    let opening: String?
    let cached: Bool
}

enum ExplorerError: Error, CustomStringConvertible {
    case rateLimited(until: Date)
    case http(Int)
    case badResponse
    case noPlayer
    case noToken

    var description: String {
        switch self {
        case .rateLimited(let until):
            let secs = max(0, Int(until.timeIntervalSinceNow))
            return "lichess is rate-limiting this address — retry in \(secs)s"
        case .http(let code): return "lichess answered HTTP \(code)"
        case .badResponse: return "lichess sent something this can't read"
        case .noPlayer: return "set a lichess username in the panel's settings"
        case .noToken: return "lichess needs your API token — add one in the panel's settings (⚙)"
        }
    }
}

/// The lichess opening explorer (explorer.lichess.ovh). Three things make
/// it a good neighbour rather than a nuisance:
///
/// - **The user's own token.** The explorer stopped serving anonymous
///   requests (401). A token shipped inside the app would be one quota
///   shared by everyone and readable out of the binary, so the app never
///   carries one: the user makes a read-only token on lichess.org and it
///   goes to the Keychain.
/// - **A position is fetched once.** Results are cached on disk by the
///   four position fields (move counters differ between routes to the same
///   position). Masters never changes enough to matter; lichess and player
///   entries are kept 30 days.
/// - **429 means stop.** lichess asks for a full minute of silence after
///   one; callers get `rateLimited(until:)` without a request being made.
@MainActor
final class LichessExplorer {
    static let shared = LichessExplorer()

    private var memory: [String: (Data, Date)] = [:]
    private var retryAfter: Date?
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        config.httpAdditionalHeaders = [
            "User-Agent": "DCStudio/\(version) (+https://github.com/dancechess/studio)",
            "Accept": "application/json",
        ]
        session = URLSession(configuration: config)
    }

    /// Statistics for `fen` from `source`.
    func fetch(source: ReferenceSource, fen: String, settings: AppSettings) async throws -> ExplorerResult {
        let url = try Self.url(for: source, fen: fen, settings: settings)
        let cacheKey = "\(source.rawValue)|\(url.query ?? "")"
        if let data = cachedData(for: cacheKey, source: source) {
            return try Self.parse(data, cached: true)
        }
        if let until = retryAfter, until > Date() {
            throw ExplorerError.rateLimited(until: until)
        }
        guard let token = settings.lichessToken, !token.isEmpty else {
            throw ExplorerError.noToken
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ExplorerError.badResponse }
        if http.statusCode == 429 {
            // lichess says how long; a full minute when it does not
            let hinted = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            retryAfter = Date().addingTimeInterval(max(hinted, 1))
            throw ExplorerError.rateLimited(until: retryAfter!)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw ExplorerError.noToken }
        guard http.statusCode == 200 else { throw ExplorerError.http(http.statusCode) }
        let body = Self.lastJsonObject(in: data) // the player endpoint streams ndjson
        let result = try Self.parse(body, cached: false)
        store(body, for: cacheKey, source: source)
        return result
    }

    // MARK: request

    private static func url(for source: ReferenceSource, fen: String, settings: AppSettings) throws -> URL {
        var comps = URLComponents(string: "https://explorer.lichess.ovh/\(source.rawValue)")!
        // four fields: two routes to one position must share a cache entry
        let position = fen.split(separator: " ").prefix(4).joined(separator: " ")
        var items = [URLQueryItem(name: "fen", value: position),
                     URLQueryItem(name: "moves", value: "14"),
                     URLQueryItem(name: "topGames", value: "0")]
        switch source {
        case .masters:
            break
        case .lichess:
            items.append(URLQueryItem(name: "recentGames", value: "0"))
            items.append(URLQueryItem(name: "speeds", value: settings.lichessSpeeds))
            items.append(URLQueryItem(name: "ratings", value: settings.lichessRatings))
        case .player:
            let name = settings.lichessUsername.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ExplorerError.noPlayer }
            // the player's colour: whose move it is, i.e. "what did he play
            // here" — the panel is looked at from the student's side
            let white = fen.split(separator: " ").dropFirst().first.map { $0 == "w" } ?? true
            items.append(URLQueryItem(name: "player", value: name))
            items.append(URLQueryItem(name: "color", value: white ? "white" : "black"))
            items.append(URLQueryItem(name: "recentGames", value: "0"))
            items.append(URLQueryItem(name: "speeds", value: settings.lichessSpeeds))
            items.append(URLQueryItem(name: "modes", value: "rated,casual"))
        case .database:
            throw ExplorerError.badResponse
        }
        comps.queryItems = items
        return comps.url!
    }

    private static func lastJsonObject(in data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let last = lines.last(where: { $0.hasPrefix("{") }), lines.count > 1 {
            return Data(last.utf8)
        }
        return data
    }

    // MARK: parse

    private struct Payload: Decodable {
        struct Move: Decodable {
            let san: String
            let white: UInt32
            let draws: UInt32
            let black: UInt32
        }
        struct Opening: Decodable {
            let eco: String?
            let name: String?
        }
        let white: UInt32?
        let draws: UInt32?
        let black: UInt32?
        let moves: [Move]
        let opening: Opening?
    }

    private static func parse(_ data: Data, cached: Bool) throws -> ExplorerResult {
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ExplorerError.badResponse
        }
        let rows = p.moves.map {
            TreeMove(san: $0.san, games: $0.white + $0.draws + $0.black,
                     whiteWins: $0.white, draws: $0.draws, blackWins: $0.black)
        }
        let total = (p.white ?? 0) + (p.draws ?? 0) + (p.black ?? 0)
        let opening = [p.opening?.eco, p.opening?.name].compactMap { $0 }.joined(separator: " ")
        return ExplorerResult(rows: rows, total: total,
                              opening: opening.isEmpty ? nil : opening, cached: cached)
    }

    // MARK: cache

    private static let masterTTL: TimeInterval = .infinity
    private static let liveTTL: TimeInterval = 30 * 24 * 3600

    private static func cacheDir(_ source: ReferenceSource) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let dir = support.appendingPathComponent("DCStudio/explorer/\(source.rawValue)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFile(_ key: String, source: ReferenceSource) -> URL? {
        let hex = SHA256.hash(data: Data(key.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        return cacheDir(source)?.appendingPathComponent("\(hex).json")
    }

    private func cachedData(for key: String, source: ReferenceSource) -> Data? {
        let ttl = source == .masters ? Self.masterTTL : Self.liveTTL
        if let (data, when) = memory[key], Date().timeIntervalSince(when) < ttl { return data }
        guard let file = Self.cacheFile(key, source: source),
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let when = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(when) < ttl,
              let data = try? Data(contentsOf: file) else { return nil }
        memory[key] = (data, when)
        return data
    }

    private func store(_ data: Data, for key: String, source: ReferenceSource) {
        memory[key] = (data, Date())
        if let file = Self.cacheFile(key, source: source) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
