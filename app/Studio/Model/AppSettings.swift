import Foundation
import Observation
import Security

/// The one secret the app holds, kept where secrets go: a generic
/// password item scoped to this app's service name. A missing item reads
/// as nil, never as an error.
enum KeychainStore {
    private static let service = "com.dancechess.DCStudio"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// User-level preferences. Small on purpose: the lichess bits the
/// reference panel needs, and nothing that belongs in a game or a file.
///
/// The lichess API token is the user's own. The explorer stopped serving
/// anonymous requests, so one is required — and it must be theirs: a token
/// shipped inside the app would be one quota shared by every user and
/// readable out of the binary by anyone. It lives in the Keychain, never in
/// UserDefaults.
@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private static let usernameKey = "lichessUsername"
    private static let ratingsKey = "lichessRatings"
    private static let speedsKey = "lichessSpeeds"
    private static let sourceKey = "referenceSource"
    private static let tokenAccount = "lichess-token"
    private static let figurinesKey = "figurineNotation"
    private static let recentFilesKey = "recentFiles"
    private static let openFilesKey = "openFiles"
    /// Where to make one: a read-only token is enough.
    static let tokenURL = URL(string: "https://lichess.org/account/oauth/token/create?description=DC+Studio+opening+explorer")!

    static let ratingPresets: [(String, String)] = [
        ("all", "0,1000,1200,1400,1600,1800,2000,2200,2500"),
        ("1600+", "1600,1800,2000,2200,2500"),
        ("2000+", "2000,2200,2500"),
        ("2200+", "2200,2500"),
    ]

    /// For the Player source: whose lichess games to look at.
    var lichessUsername: String {
        didSet { UserDefaults.standard.set(lichessUsername, forKey: Self.usernameKey) }
    }
    /// Comma-separated lichess rating buckets (the explorer's own values).
    var lichessRatings: String {
        didSet { UserDefaults.standard.set(lichessRatings, forKey: Self.ratingsKey) }
    }
    var lichessSpeeds: String {
        didSet { UserDefaults.standard.set(lichessSpeeds, forKey: Self.speedsKey) }
    }
    var referenceSource: ReferenceSource {
        didSet { UserDefaults.standard.set(referenceSource.rawValue, forKey: Self.sourceKey) }
    }
    /// ♘f3 rather than Nf3 in the notation panel and on paper. On by
    /// default, as in ChessBase; the PGN itself always keeps letters.
    var figurines: Bool {
        didSet { UserDefaults.standard.set(figurines, forKey: Self.figurinesKey) }
    }
    /// Recently opened PGN paths, newest first (File ▸ Open Recent).
    private(set) var recentFiles: [String]
    /// The files open when the app last ran, in window order — reopened
    /// as tabs on launch.
    var openFiles: [String] {
        didSet { UserDefaults.standard.set(openFiles, forKey: Self.openFilesKey) }
    }

    func rememberRecent(_ url: URL) {
        let path = url.path
        var list = recentFiles.filter { $0 != path }
        list.insert(path, at: 0)
        recentFiles = Array(list.prefix(8))
        UserDefaults.standard.set(recentFiles, forKey: Self.recentFilesKey)
    }

    func clearRecents() {
        recentFiles = []
        UserDefaults.standard.removeObject(forKey: Self.recentFilesKey)
    }

    /// Keychain-backed; nil when unset.
    private(set) var lichessToken: String?

    func setLichessToken(_ token: String?) {
        let clean = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        lichessToken = (clean?.isEmpty ?? true) ? nil : clean
        KeychainStore.set(lichessToken, for: Self.tokenAccount)
    }

    private init() {
        let d = UserDefaults.standard
        lichessUsername = d.string(forKey: Self.usernameKey) ?? ""
        lichessRatings = d.string(forKey: Self.ratingsKey) ?? "1600,1800,2000,2200,2500"
        lichessSpeeds = d.string(forKey: Self.speedsKey) ?? "blitz,rapid,classical"
        referenceSource = ReferenceSource(rawValue: d.string(forKey: Self.sourceKey) ?? "") ?? .database
        figurines = d.object(forKey: Self.figurinesKey) as? Bool ?? true
        recentFiles = d.stringArray(forKey: Self.recentFilesKey) ?? []
        // first launch after the single-list days: the last list becomes the
        // first tab, so nothing the user had open goes missing
        openFiles = d.stringArray(forKey: Self.openFilesKey)
            ?? (d.stringArray(forKey: "lastSourcePaths") ?? [])
        lichessToken = KeychainStore.get(Self.tokenAccount)
        // dev hook: a token for a smoke run, without touching the Keychain
        if let env = ProcessInfo.processInfo.environment["DCS_LICHESS_TOKEN"], !env.isEmpty {
            lichessToken = env
        }
    }
}
