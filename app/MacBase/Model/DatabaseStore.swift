import CryptoKit
import Foundation
import Observation
#if canImport(MacBaseCore)
import MacBaseCore
#endif

/// The PGN file is the source of truth; SQLite is a per-file speed cache
/// (fast paging for 100k-game lists, opening-tree index). Opening a PGN
/// replaces the list: each file (or multi-selection) gets its own cache db
/// under `<Application Support>/MacBase/caches/`, rebuilt only when the
/// source file is newer than the cache. Edits (update_game) land in the
/// cache — they survive reopen until the source PGN itself changes.
@Observable
@MainActor
final class DatabaseStore {
    static let shared = DatabaseStore()

    private(set) var db: Database?
    /// Display name of what's open (file stem, "+N" for multi-selections).
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

    /// When set (reference mode), the list shows only games reaching this
    /// position; nil = the whole list.
    private(set) var positionFilter: String?
    private(set) var matchedCount: UInt64 = 0
    /// What the table actually shows (position filter beats text search).
    var displayCount: UInt64 {
        if positionFilter != nil { return matchedCount }
        if searchText != nil { return searchCount }
        return gameCount
    }

    /// Source PGN files behind the current list.
    private(set) var sourceURLs: [URL] = []
    private var cacheURL: URL?

    /// Manual entry / write-back needs exactly one source file — a merged
    /// multi-file list has no unambiguous home for a new game.
    var canWriteBack: Bool { db != nil && sourceURLs.count == 1 }

    /// Recently opened PGN paths, newest first (File ▸ Open Recent).
    private(set) var recentFiles: [String] = []

    /// Source files already backed up this launch (one .bak per file per
    /// run — a safety net for the whole-file write-back).
    private var backedUpPaths: Set<String> = []

    private static let lastCachePathKey = "lastCachePath"
    private static let lastSourceNameKey = "lastSourceName"
    private static let lastSourcePathsKey = "lastSourcePaths"
    private static let recentFilesKey = "recentFiles"
    static let lastSelectedGameKey = "lastSelectedGameId"

    private init() {
        // reopen the last cache so the app starts where it left off; the
        // freshness check against sources only runs on an explicit Open
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Self.lastCachePathKey),
           FileManager.default.fileExists(atPath: path) {
            do {
                let db = try Database.open(path: path)
                self.db = db
                cacheURL = URL(fileURLWithPath: path)
                gameCount = (try? db.gameCount()) ?? 0
                sourceName = defaults.string(forKey: Self.lastSourceNameKey)
                sourceURLs = (defaults.stringArray(forKey: Self.lastSourcePathsKey) ?? [])
                    .map { URL(fileURLWithPath: $0) }
            } catch {
                errorText = "Can't open cached list: \(error.localizedDescription)"
            }
        } else {
            statusText = "Open a PGN file to begin"
        }
        recentFiles = defaults.stringArray(forKey: Self.recentFilesKey) ?? []
    }

    func clearRecents() {
        recentFiles = []
        UserDefaults.standard.removeObject(forKey: Self.recentFilesKey)
    }

    private func rememberRecent(_ urls: [URL]) {
        guard urls.count == 1, let path = urls.first?.path else { return }
        var list = recentFiles.filter { $0 != path }
        list.insert(path, at: 0)
        recentFiles = Array(list.prefix(8))
        UserDefaults.standard.set(recentFiles, forKey: Self.recentFilesKey)
    }

    /// Synchronous paged fetch for the table's data source; SQLite with
    /// LIMIT/OFFSET is fast enough to stay on the main thread here.
    func page(offset: UInt64, limit: UInt32) -> [GameSummary] {
        guard let db else { return [] }
        do {
            if let fen = positionFilter {
                return try db.gamesAtPosition(fen: fen, offset: offset, limit: limit,
                                              sort: sort, ascending: ascending)
            }
            if let text = searchText {
                return try db.searchGames(text: text, offset: offset, limit: limit,
                                          sort: sort, ascending: ascending)
            }
            return try db.listGames(offset: offset, limit: limit,
                                    sort: sort, ascending: ascending)
        } catch {
            errorText = "Failed to load game list: \(error.localizedDescription)"
            return []
        }
    }

    /// Text search over White/Black/Event (nil clears). Ignored while the
    /// reference-mode position filter is active.
    private(set) var searchText: String?
    private(set) var searchCount: UInt64 = 0

    func setSearch(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespaces)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard value != searchText else { return }
        searchText = value
        if let value, let db {
            searchCount = (try? db.searchGamesCount(text: value)) ?? 0
        } else {
            searchCount = 0
        }
        revision += 1
    }

    /// Deletes one game from the cache and the source PGN.
    func deleteGame(id: Int64) {
        guard let db else { return }
        do {
            try db.deleteGame(id: id)
            try writeBack()
            gameCount = (try? db.gameCount()) ?? 0
            if let fen = positionFilter {
                matchedCount = (try? db.gamesAtPositionCount(fen: fen)) ?? 0
            }
            if let text = searchText {
                searchCount = (try? db.searchGamesCount(text: text)) ?? 0
            }
            revision += 1
        } catch {
            errorText = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Reference mode: filter the list to games reaching `fen` (nil clears).
    func setPositionFilter(_ fen: String?) {
        guard fen != positionFilter else { return }
        positionFilter = fen
        if let fen, let db {
            matchedCount = (try? db.gamesAtPositionCount(fen: fen)) ?? 0
        } else {
            matchedCount = 0
        }
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
        revision += 1
    }

    /// Appends a manually entered game to the list and the source PGN.
    func addGame(pgn: String) throws -> Int64 {
        guard let db, canWriteBack else {
            throw ChessError.Database(reason: "no single PGN file to save into")
        }
        let id = try db.addGame(pgn: pgn)
        try writeBack()
        gameCount = (try? db.gameCount()) ?? gameCount
        revision += 1
        return id
    }

    /// Creates an empty PGN file and opens it as the current (0-game) list.
    func createNewPgn(at url: URL) {
        do {
            try Data().write(to: url)
            openPgn([url])
        } catch {
            errorText = "Can't create file: \(error.localizedDescription)"
        }
    }

    /// Regenerates the source .pgn from the cache (atomic temp+rename in
    /// Rust), then touches the cache so it still reads as fresh.
    private func writeBack() throws {
        guard let db, canWriteBack, let source = sourceURLs.first else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        // first write to this file this launch: keep a .bak of the original
        if !backedUpPaths.contains(source.path),
           FileManager.default.fileExists(atPath: source.path) {
            let bak = source.path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.copyItem(atPath: source.path, toPath: bak)
            backedUpPaths.insert(source.path)
        }
        try db.writePgnFile(path: source.path)
        if let cacheURL {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: cacheURL.path)
        }
    }

    /// Opens PGN file(s), replacing the current list. Reuses the file's
    /// cache when it is newer than every source; otherwise rebuilds it.
    func openPgn(_ urls: [URL]) {
        guard !urls.isEmpty, !importing else { return }
        importing = true
        errorText = nil
        // sessions still point at games of the previous list — their edits
        // become scratch rather than writing into the wrong game
        GameSession.SessionRegistry.shared.detachAll()
        Task {
            var cacheURL: URL?
            do {
                cacheURL = try Self.cacheURL(for: urls)
                try await open(urls: urls, cacheURL: cacheURL!)
            } catch {
                // a half-built cache must not pass the next freshness check
                if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
                errorText = "Open failed — \(error.localizedDescription)"
                statusText = nil
            }
            importing = false
        }
    }

    private func open(urls: [URL], cacheURL: URL) async throws {
        let scopes = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, scoped) in scopes where scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let name = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "\(urls[0].deletingPathExtension().lastPathComponent) +\(urls.count - 1)"
        let fresh = Self.cacheIsFresh(cacheURL, sources: urls)
        let db = try Database.open(path: cacheURL.path)
        if fresh {
            self.db = db
            gameCount = (try? db.gameCount()) ?? 0
            statusText = "opened from cache"
        } else {
            statusText = "Importing…"
            try await Self.runClear(db: db)
            var imported: UInt32 = 0
            var skipped: UInt32 = 0
            var millis: UInt64 = 0
            for url in urls {
                let stats = try await Self.runImport(db: db, path: url.path)
                imported += stats.imported
                skipped += stats.skipped
                millis += stats.millis
            }
            self.db = db
            gameCount = (try? db.gameCount()) ?? 0
            statusText = String(format: "imported %d games (%d skipped) in %.1fs",
                                imported, skipped, Double(millis) / 1000)
        }
        sourceName = name
        sourceURLs = urls
        self.cacheURL = cacheURL
        positionFilter = nil
        matchedCount = 0
        searchText = nil
        searchCount = 0
        generation += 1
        revision += 1
        UserDefaults.standard.set(cacheURL.path, forKey: Self.lastCachePathKey)
        UserDefaults.standard.set(name, forKey: Self.lastSourceNameKey)
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.lastSourcePathsKey)
        rememberRecent(urls)
    }

    /// One cache db per source selection, keyed by the full path set.
    private static func cacheURL(for urls: [URL]) throws -> URL {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("MacBase/caches", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = urls.map(\.path).sorted().joined(separator: "\n")
        let hex = SHA256.hash(data: Data(key.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let stem = urls[0].deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent("\(stem)-\(hex).db")
    }

    /// Fresh = the cache file is newer than every source PGN. Edits keep
    /// bumping the cache's mtime, so they never mark it stale themselves.
    private static func cacheIsFresh(_ cache: URL, sources: [URL]) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: cache.path),
              let cacheDate = attrs[.modificationDate] as? Date else { return false }
        for url in sources {
            guard let a = try? fm.attributesOfItem(atPath: url.path),
                  let sourceDate = a[.modificationDate] as? Date,
                  sourceDate <= cacheDate else { return false }
        }
        return true
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
