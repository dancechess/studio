import AppKit
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

/// Typefaces offered for the notation panel. Every one of them ships with
/// macOS: a font that has to be downloaded is a font that silently renders
/// as something else on the next Mac, and notation is the one text in this
/// app a reader stares at for an hour.
///
/// Two of them are asked for by *design* rather than by name — New York and
/// SF Mono are system faces whose family names are private (".AppleSystemUIFontSerif")
/// and have changed between releases. Asking the system for a serif is
/// stable; asking for a file name is not.
enum NotationFace: String, CaseIterable, Identifiable, Sendable {
    case newYork, system, charter, iowan, avenirNext, sfMono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newYork: return "New York"
        case .system: return "System"
        case .charter: return "Charter"
        case .iowan: return "Iowan Old Style"
        case .avenirNext: return "Avenir Next"
        case .sfMono: return "SF Mono"
        }
    }

    /// What it looks like, in three words, for the settings popup.
    var note: String {
        switch self {
        case .newYork: return "serif, made for reading"
        case .system: return "San Francisco"
        case .charter: return "compact serif"
        case .iowan: return "book serif"
        case .avenirNext: return "geometric sans"
        case .sfMono: return "monospaced"
        }
    }

    fileprivate var design: NSFontDescriptor.SystemDesign? {
        switch self {
        case .newYork: return .serif
        case .sfMono: return .monospaced
        case .system: return .default
        default: return nil
        }
    }

    fileprivate var family: String? {
        switch self {
        case .charter: return "Charter"
        case .iowan: return "Iowan Old Style"
        case .avenirNext: return "Avenir Next"
        default: return nil
        }
    }

    /// The font, or the system font at the same size if this Mac turns out
    /// not to have the family after all. A missing font must never mean a
    /// missing notation panel.
    func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: weight)
        if let family {
            var descriptor = NSFontDescriptor(fontAttributes: [.family: family])
            if weight >= .semibold {
                descriptor = descriptor.withSymbolicTraits(.bold)
            }
            return NSFont(descriptor: descriptor, size: size) ?? fallback
        }
        guard let design, let descriptor = fallback.fontDescriptor.withDesign(design) else {
            return fallback
        }
        return NSFont(descriptor: descriptor, size: size) ?? fallback
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
    private static let faceKey = "notationFace"
    private static let fontSizeKey = "notationFontSize"
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
    /// ♘f3 rather than Nf3 in the notation panel and on paper. Off by
    /// default — ChessBase shows letters, and that is what its users read;
    /// the PGN itself always keeps letters either way.
    var figurines: Bool {
        didSet { UserDefaults.standard.set(figurines, forKey: Self.figurinesKey) }
    }
    /// The notation panel's typeface, and the size the main line is set
    /// in. Everything else in the right-hand column is derived from this
    /// one number, so the panel, the engine lines and the opening tree
    /// stay in proportion rather than drifting apart.
    var notationFace: NotationFace {
        didSet { UserDefaults.standard.set(notationFace.rawValue, forKey: Self.faceKey) }
    }
    /// Clamped through `setNotationFontSize` rather than in a `didSet`:
    /// @Observable rewrites stored properties as computed ones, so a
    /// property assigning to itself in its own observer recurses until the
    /// stack goes (the engine panel's +/- crashed exactly this way).
    private(set) var notationFontSize: Double {
        didSet { UserDefaults.standard.set(notationFontSize, forKey: Self.fontSizeKey) }
    }

    static let fontSizeRange: ClosedRange<Double> = 11...22

    func setNotationFontSize(_ size: Double) {
        notationFontSize = min(max(size.rounded(), Self.fontSizeRange.lowerBound),
                               Self.fontSizeRange.upperBound)
    }

    /// Engine lines and opening-tree rows: a notch below the main line,
    /// never below legibility.
    var panelFontSize: Double { max(11, notationFontSize - 2) }
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
        figurines = d.object(forKey: Self.figurinesKey) as? Bool ?? false
        // resolved before the assignment, not after: a second write to one
        // of these inside init goes through the observer and would save the
        // screenshot run's font as the user's preference
        var face = NotationFace(rawValue: d.string(forKey: Self.faceKey) ?? "") ?? .newYork
        var fontSize = d.object(forKey: Self.fontSizeKey) as? Double ?? 14
        // dev hook: DCS_NOTATION_FONT=charter:20 — a face and size for a
        // screenshot run, left out of the saved preferences
        if let env = ProcessInfo.processInfo.environment["DCS_NOTATION_FONT"], !env.isEmpty {
            let parts = env.split(separator: ":")
            if let parsed = NotationFace(rawValue: String(parts[0])) { face = parsed }
            if parts.count > 1, let parsed = Double(parts[1]) { fontSize = parsed }
        }
        notationFace = face
        notationFontSize = fontSize
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
