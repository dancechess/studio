import AppKit
import CryptoKit
import Foundation
import Observation
#if canImport(DanceChessCore)
import DanceChessCore
#endif

/// One open PGN file: the list a window shows. The PGN is the source of
/// truth; SQLite is a per-file speed cache (fast paging for 100k-game
/// lists, opening-tree index) under `<Application Support>/DCStudio/caches/`,
/// rebuilt only when the source file is newer than the cache. Edits
/// (update_game) land in the cache and are written back to the file.
///
/// There is one of these per window, never shared: a file open in two
/// places would be two caches writing the whole file over each other, so
/// the app opens a file once and brings that window forward instead. The
/// live ones are listed in `OpenStores`.
@Observable
@MainActor
final class DatabaseStore {
    private(set) var db: Database?
    /// Display name of what's open (the file stem).
    private(set) var sourceName: String?
    private(set) var gameCount: UInt64 = 0
    /// Bumped whenever the table must drop its page cache and reload
    /// (open, sort change, save-back).
    private(set) var revision = 0
    /// Bumped only when a DIFFERENT list is opened: ids now mean other
    /// games, so selection pinning must reset instead of silently keeping
    /// the same-numbered row (which would leave a stale game on the board).
    private(set) var generation = 0
    private(set) var importing = false
    private(set) var statusText: String?
    private(set) var errorText: String?

    private(set) var sort: GameSort = .number
    private(set) var ascending = true

    /// Everything the list is narrowed by — text, result, dates, Elo, and
    /// the reference-mode position — combined with AND in one SQL query.
    /// A default filter is the whole list.
    private(set) var filter = GameFilter(text: nil, result: nil, dateFrom: nil,
                                         dateTo: nil, minElo: nil, maxElo: nil, fen: nil)
    /// Row count under `filter` (== gameCount when the filter is empty).
    private(set) var filteredCount: UInt64 = 0
    var isFiltered: Bool {
        filter.text != nil || filter.result != nil || filter.dateFrom != nil
            || filter.dateTo != nil || filter.minElo != nil || filter.maxElo != nil
            || filter.fen != nil
    }
    /// Reference mode's position, when active.
    var positionFilter: String? { filter.fen }
    var matchedCount: UInt64 { filteredCount }
    /// What the table actually shows.
    var displayCount: UInt64 { isFiltered ? filteredCount : gameCount }

    private func recount() {
        guard let db else { filteredCount = 0; return }
        filteredCount = isFiltered ? ((try? db.countGames(filter: filter)) ?? 0) : gameCount
    }

    /// The PGN file behind the list (nil = nothing open in this window).
    private(set) var sourceURL: URL?
    private var cacheURL: URL?

    var canWriteBack: Bool { db != nil && sourceURL != nil }

    /// The window showing this list, for "that file is already open".
    weak var window: NSWindow?

    func bringWindowForward() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Source files already backed up this launch (one .bak per file per
    /// run — a safety net for the whole-file write-back). App-wide, since
    /// the same file can be opened, closed and opened again.
    private static var backedUpPaths: Set<String> = []

    init() {
        Self.migrateLegacyStorage()
        statusText = "Open a PGN file to begin"
    }

    /// The canonical form every path comparison uses: one file must be one
    /// window whatever the spelling, and a symlink is the same file.
    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: per-file memory (the game you were looking at)

    private var selectedGameKey: String? {
        sourceURL.map { "selectedGame:\($0.path)" }
    }

    /// The game last viewed in this file, restored when the list opens.
    var lastSelectedGameId: Int64? {
        guard let key = selectedGameKey else { return nil }
        return UserDefaults.standard.object(forKey: key) as? Int64
    }

    func rememberSelected(_ id: Int64) {
        if let key = selectedGameKey { UserDefaults.standard.set(id, forKey: key) }
    }

    /// One-time move of the pre-rename storage directory (MacBase →
    /// DCStudio), so existing caches survive; cached-file names are keyed
    /// by source path, so reopening the same PGN hits them instantly.
    private static func migrateLegacyStorage() {
        guard let support = try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true) else { return }
        let legacy = support.appendingPathComponent("MacBase", isDirectory: true)
        let home = support.appendingPathComponent("DCStudio", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: home.path) {
            try? FileManager.default.moveItem(at: legacy, to: home)
        }
    }

    func setStatus(_ text: String) { statusText = text }

    /// Synchronous paged fetch for the table's data source; SQLite with
    /// LIMIT/OFFSET is fast enough to stay on the main thread here.
    func page(offset: UInt64, limit: UInt32) -> [GameSummary] {
        guard let db else { return [] }
        do {
            return try db.queryGames(filter: filter, offset: offset, limit: limit,
                                     sort: sort, ascending: ascending)
        } catch {
            errorText = "Failed to load game list: \(error.localizedDescription)"
            return []
        }
    }

    /// Text search over White/Black/Event (nil or blank clears).
    var searchText: String? { filter.text }

    func setSearch(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespaces)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard value != filter.text else { return }
        filter.text = value
        recount()
        revision += 1
    }

    /// Header criteria from the filter popover. Blank strings and nil both
    /// mean "no bound"; Elo bounds apply to both players.
    func setHeaderFilter(result: String?, dateFrom: String?, dateTo: String?,
                         minElo: UInt32?, maxElo: UInt32?) {
        let clean = { (v: String?) -> String? in
            let t = v?.trimmingCharacters(in: .whitespaces)
            return (t?.isEmpty ?? true) ? nil : t
        }
        let next = (clean(result), clean(dateFrom), clean(dateTo), minElo, maxElo)
        let cur = (filter.result, filter.dateFrom, filter.dateTo, filter.minElo, filter.maxElo)
        guard next != cur else { return }
        (filter.result, filter.dateFrom, filter.dateTo, filter.minElo, filter.maxElo) = next
        recount()
        revision += 1
    }

    func clearHeaderFilter() {
        setHeaderFilter(result: nil, dateFrom: nil, dateTo: nil, minElo: nil, maxElo: nil)
    }

    /// Deletes one game from the cache and the source PGN.
    func deleteGame(id: Int64) {
        guard let db else { return }
        do {
            try db.deleteGame(id: id)
            try writeBack()
            gameCount = (try? db.gameCount()) ?? 0
            recount()
            revision += 1
        } catch {
            errorText = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Reference mode: filter the list to games reaching `fen` (nil clears).
    func setPositionFilter(_ fen: String?) {
        guard fen != filter.fen else { return }
        filter.fen = fen
        recount()
        revision += 1
    }

    func setSort(_ sort: GameSort, ascending: Bool) {
        guard sort != self.sort || ascending != self.ascending else { return }
        self.sort = sort
        self.ascending = ascending
        revision += 1
    }

    func pgn(for id: Int64) -> String? {
        guard let db else { return nil }
        do {
            return try db.gamePgn(id: id)
        } catch {
            errorText = "Failed to load game: \(error.localizedDescription)"
            return nil
        }
    }

    /// Writes an edited game into the cache (Rust re-parses, re-normalizes
    /// and rebuilds its opening-tree rows), then back into the source PGN.
    func updateGame(id: Int64, pgn: String) throws {
        guard let db else { throw ChessError.Database(reason: "no database") }
        try db.updateGame(id: id, pgn: pgn)
        try writeBack()
        recount()
        revision += 1
    }

    /// Appends a manually entered game to the list and the source PGN.
    func addGame(pgn: String) throws -> Int64 {
        guard let db, canWriteBack else {
            throw ChessError.Database(reason: "no PGN file to save into")
        }
        let id = try db.addGame(pgn: pgn)
        try writeBack()
        gameCount = (try? db.gameCount()) ?? gameCount
        recount()
        revision += 1
        return id
    }

    /// Creates an empty PGN file on disk (the caller then opens it).
    static func createEmptyPgn(at url: URL) throws {
        try Data().write(to: url)
    }

    /// Regenerates the source .pgn from the cache (atomic temp+rename in
    /// Rust), then touches the cache so it still reads as fresh.
    private func writeBack() throws {
        guard let db, canWriteBack, let source = sourceURL else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        // first write to this file this launch: keep a .bak of the original
        if !Self.backedUpPaths.contains(source.path),
           FileManager.default.fileExists(atPath: source.path) {
            let bak = source.path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.copyItem(atPath: source.path, toPath: bak)
            Self.backedUpPaths.insert(source.path)
        }
        try db.writePgnFile(path: source.path)
        if let cacheURL {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: cacheURL.path)
        }
    }

    /// Loads one PGN file into this (empty) store. Reuses the file's cache
    /// when it is newer than the source; otherwise rebuilds it. A store
    /// loads once: a window shows one file for its whole life.
    func load(_ url: URL) {
        guard sourceURL == nil, !importing else { return }
        let url = Self.canonical(url)
        importing = true
        errorText = nil
        sourceURL = url
        sourceName = url.deletingPathExtension().lastPathComponent
        OpenStores.shared.register(self)
        AppSettings.shared.rememberRecent(url)
        Task {
            var cacheURL: URL?
            do {
                cacheURL = try Self.cacheURL(for: url)
                try await open(url: url, cacheURL: cacheURL!)
            } catch {
                // a half-built cache must not pass the next freshness check
                if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
                errorText = "Open failed — \(error.localizedDescription)"
                statusText = nil
            }
            importing = false
        }
    }

    private func open(url: URL, cacheURL: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fresh = Self.cacheIsFresh(cacheURL, source: url)
        let db = try Database.open(path: cacheURL.path)
        if fresh {
            self.db = db
            gameCount = (try? db.gameCount()) ?? 0
            statusText = "opened from cache"
        } else {
            statusText = "Importing…"
            try await Self.runClear(db: db)
            let stats = try await Self.runImport(db: db, path: url.path)
            self.db = db
            gameCount = (try? db.gameCount()) ?? 0
            statusText = String(format: "imported %d games (%d skipped) in %.1fs",
                                stats.imported, stats.skipped, Double(stats.millis) / 1000)
        }
        self.cacheURL = cacheURL
        filter = GameFilter(text: nil, result: nil, dateFrom: nil, dateTo: nil,
                            minElo: nil, maxElo: nil, fen: nil)
        filteredCount = gameCount
        generation += 1
        revision += 1
    }

    /// One cache db per source file, keyed by its canonical path.
    private static func cacheURL(for url: URL) throws -> URL {
        let support = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("DCStudio/caches", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hex = SHA256.hash(data: Data(url.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let stem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent("\(stem)-\(hex).db")
    }

    /// Fresh = the cache file is newer than the source PGN. Edits keep
    /// bumping the cache's mtime, so they never mark it stale themselves.
    private static func cacheIsFresh(_ cache: URL, source: URL) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: cache.path),
              let cacheDate = attrs[.modificationDate] as? Date,
              let a = try? fm.attributesOfItem(atPath: source.path),
              let sourceDate = a[.modificationDate] as? Date else { return false }
        return sourceDate <= cacheDate
    }

    private nonisolated static func runClear(db: Database) async throws {
        try await Task.detached { try db.clearAll() }.value
    }

    private nonisolated static func runImport(db: Database, path: String) async throws -> ImportStats {
        try await Task.detached(priority: .userInitiated) {
            try db.importPgnFile(path: path)
        }.value
    }
}


/// The files open right now, one store each — what "open this file" checks
/// before opening it again, what Copy Games To lists, and what is written
/// down for the next launch. Weak, so a closed window drops out on its own.
@MainActor
final class OpenStores {
    static let shared = OpenStores()
    private struct WeakBox { weak var store: DatabaseStore? }
    private var boxes: [WeakBox] = []

    var all: [DatabaseStore] { boxes.compactMap(\.store) }

    /// Set when the app is quitting: the windows close one by one from
    /// here on, and each one leaving must not shrink the restore list —
    /// that is exactly the set the next launch should bring back. Found
    /// the hard way: a headless test that killed the process restored
    /// fine, and a real ⌘Q came back to nothing.
    private(set) var quitting = false

    func freezeForQuit() {
        persist()
        quitting = true
    }

    func register(_ store: DatabaseStore) {
        boxes.removeAll { $0.store == nil || $0.store === store }
        boxes.append(WeakBox(store: store))
        persist()
    }

    /// A window closed. During a quit the list is already frozen.
    func unregister(_ store: DatabaseStore) {
        boxes.removeAll { $0.store == nil || $0.store === store }
        if !quitting { persist() }
    }

    /// The store showing `url`, if any window has it.
    func store(for url: URL) -> DatabaseStore? {
        let key = DatabaseStore.canonical(url)
        return all.first { $0.sourceURL == key }
    }

    /// The open files, in window order, for restoring on the next launch.
    private func persist() {
        AppSettings.shared.openFiles = all.compactMap { $0.sourceURL?.path }
    }
}
