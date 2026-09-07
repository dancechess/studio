import SwiftUI
import UniformTypeIdentifiers
#if canImport(DanceChessCore)
import DanceChessCore
#endif

/// The single main window: board + notation on top, the database's game
/// list below (ChessBase's two windows folded into one).
///
/// Two-state focus model:
/// - **Browse** (list focused): ↑↓ switch games (board follows), ←→ step
///   through the previewed game without leaving the list, Enter engages.
/// - **Engaged** (game focused, accent border): the full M1 key table
///   (↑↓ sibling variations, branch popup, Home/End); Esc returns to browse.
/// - ⌥↑ / ⌥↓ switch games in either state; ⌘-double-click opens the game
///   in a standalone window.
/// Leaving a modified game prompts to save (ChessBase style; update_game
/// writes back through Rust).
struct MainWindow: View {
    /// The file this window shows. nil only for the window SwiftUI opens
    /// at launch before anything is restored into it.
    @Binding var url: URL?
    @State private var store: DatabaseStore
    @State private var session = GameSession()
    @State private var engine = EngineSession()
    @State private var tree: OpeningTreeModel
    @State private var keyObservers: [NSObjectProtocol] = []
    @State private var engaged = false

    init(url: Binding<URL?>) {
        _url = url
        let store = DatabaseStore()
        _store = State(initialValue: store)
        _tree = State(initialValue: OpeningTreeModel(store: store))
    }

    /// Restoration runs once per launch, in whichever window appears first.
    @MainActor private static var restored = false
    /// This window arrived empty after launch — the tab bar's "+" (or
    /// Window ▸ New Tab), which SwiftUI answers by opening the group's
    /// scene with no value. Such a window asks for a file the moment it
    /// has an NSWindow, and closes itself if none is chosen.
    @State private var wantsFile = false
    @State private var listController = GameListController()
    @State private var keyMonitor = KeyEventMonitor()
    @State private var mouseMonitor = KeyEventMonitor()
    @State private var closeSaver = WindowCloseSaver()
    @State private var hostWindow: NSWindow?
    @State private var showSaveSheet = false
    @State private var showSetupSheet = false
    @State private var showAnalyzeSheet = false
    @State private var analyzer = GameAnalyzer()
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var showFilters = false
    @State private var filterResult = ""
    @State private var filterDateFrom = ""
    @State private var filterDateTo = ""
    @State private var filterMinElo = ""
    @State private var filterMaxElo = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VSplitView {
            GameArea(session: session, engine: engine, tree: tree)
                .overlay {
                    if engaged {
                        Rectangle()
                            .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 380)

            VStack(spacing: 0) {
                if store.externallyChanged { changedOnDiskBanner }
                searchBar
                Divider()
                GameListView(
                    store: store,
                    revision: store.revision,
                    generation: store.generation,
                    count: store.displayCount,
                    controller: listController,
                    shouldLeaveGame: { confirmLeaveGame() },
                    onSelect: { loadSelected($0) },
                    onActivate: { id, commandKey in
                        if commandKey {
                            openWindow(id: "game", value: GameRef(path: store.sourceURL?.path, id: id))
                        } else if store.canWriteBack {
                            // the row is already selected & loaded — edit it
                            showSaveSheet = true
                        } else {
                            setEngaged(true)
                        }
                    },
                    onDeleteRequest: { confirmAndDelete($0) },
                    onMergeRequest: { mergeGames($0) },
                    onCopyRequest: { ids, target in copyGames(ids, to: target) },
                    initialSelection: store.lastSelectedGameId
                )
                Divider()
                statusBar
            }
            .frame(minHeight: 160)
        }
        .background(WindowReader { window in
            if hostWindow !== window {
                hostWindow = window
                closeSaver.attach(window: window, session: session)
                store.window = window
                attachWindow(window)
                if wantsFile { askForFile() }
            }
        })
        .onChange(of: url, initial: true) {
            if let url { store.load(url) }
        }
        .onAppear {
            session.store = store
            keyMonitor.install { handleKey($0) }
            // any window can open more; the newest to appear holds the
            // environment's openWindow
            FileOpener.shared.install { openWindow(value: $0) }
            let launchWindow = !Self.restored
            restoreIfFirst()
            if url == nil, !launchWindow {
                wantsFile = true
                if hostWindow != nil { askForFile() }
            }
            // dev hook (like DCS_KEY_DEBUG): open the engine panel on
            // launch and jump to the game's end so smoke runs can screenshot
            // live analysis without pressing ⌘E (engine idles at the root)
            if let mode = ProcessInfo.processInfo.environment["DCS_AUTO_ENGINE"] {
                engine.togglePanel(target: session.highlightedFen)
                if mode != "root" { // "root" stays put (FEN-game screenshots)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        session.toEnd()
                    }
                }
            }
            // dev hook: open PGN(s) on launch, comma-separated — the first
            // into this window, the rest as further tabs
            if launchWindow, url == nil,
               let paths = ProcessInfo.processInfo.environment["DCS_AUTO_OPEN"] {
                let urls = paths.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
                if let first = urls.first, FileOpener.shared.claim(first) {
                    url = DatabaseStore.canonical(first)
                }
                for more in urls.dropFirst() { FileOpener.shared.open(more) }
            }
            // dev hook: edit + save game 1 of THIS window's file (the save
            // must touch this file and no other open one)
            if let which = ProcessInfo.processInfo.environment["DCS_AUTO_TAB_SAVE"],
               url?.lastPathComponent == which {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    guard let pgn = store.pgn(for: 1) else { return }
                    session.loadPgn(pgn, sourceId: 1)
                    session.toEnd()
                    session.applyNag(1)
                    SavePrompt.save(session)
                }
            }
            // dev hook: the tab bar's "+", sent the way the button sends it
            if ProcessInfo.processInfo.environment["DCS_AUTO_PLUS"] != nil, url != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
                }
            }
            // dev hook: copy games 1–2 of THIS window's file into the other
            // open file, then report (run twice to see duplicates skipped)
            if let which = ProcessInfo.processInfo.environment["DCS_AUTO_COPY"],
               url?.lastPathComponent == which {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard let target = OpenStores.shared.all.first(where: { $0 !== store }) else { return }
                    let before = target.gameCount
                    copyGames([1, 2], to: target)
                    let out = ProcessInfo.processInfo.environment["DCS_AUTO_COPY_OUT"] ?? "/tmp/dcs-copy.txt"
                    try? "target before: \(before) after: \(target.gameCount)\nsource status: \(store.statusText ?? "-")\ntarget status: \(target.statusText ?? "-")\n"
                        .write(toFile: out, atomically: true, encoding: .utf8)
                }
            }
            // dev hook: the file-changed banner — report after a delay,
            // optionally reloading first
            if let out = ProcessInfo.processInfo.environment["DCS_AUTO_WATCH_OUT"], url != nil {
                if ProcessInfo.processInfo.environment["DCS_AUTO_WATCH_RELOAD"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { store.reloadFromDisk() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                    try? "changed: \(store.externallyChanged)\ngames: \(store.gameCount)\nstatus: \(store.statusText ?? "-")\n"
                        .write(toFile: out, atomically: true, encoding: .utf8)
                }
            }
            // dev hook: report the windows/tabs and engine states
            if let out = ProcessInfo.processInfo.environment["DCS_AUTO_TABS_OUT"], url != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let windows = NSApp.windows.filter { $0.tabbingIdentifier == "dcstudio-database" && $0.isVisible }
                    var text = "windows: \(windows.count)\n"
                    for w in windows {
                        text += "  \(w.title) tabbed=\(w.tabbedWindows?.count ?? 0) key=\(w.isKeyWindow)\n"
                    }
                    text += "open files: \(OpenStores.shared.all.compactMap { $0.sourceURL?.lastPathComponent })\n"
                    text += "restore list: \(AppSettings.shared.openFiles.map { ($0 as NSString).lastPathComponent })\n"
                    try? text.write(toFile: out, atomically: true, encoding: .utf8)
                }
            }
            // dev hook: pop the game-info sheet (layout screenshots)
            if ProcessInfo.processInfo.environment["DCS_AUTO_INFO"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showSaveSheet = true
                }
            }
            // dev hook: dump the menu bar to a file (wiring verification)
            if let path = ProcessInfo.processInfo.environment["DCS_DEBUG_MENU"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    var out = ""
                    for menu in NSApp.mainMenu?.items ?? [] {
                        out += "MENU: \(menu.title)\n"
                        for item in menu.submenu?.items ?? [] where !item.isSeparatorItem {
                            out += "  - \(item.title) [\(item.keyEquivalent)]\n"
                        }
                    }
                    try? out.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
            // dev hook: bump MultiPV programmatically (button diagnosis)
            if ProcessInfo.processInfo.environment["DCS_AUTO_MPV"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    engine.setMultiPV(engine.multiPV + 1)
                }
            }
            // dev hook: draw sample annotations (screenshots)
            if ProcessInfo.processInfo.environment["DCS_AUTO_ANNOTATE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    session.toEnd()
                    session.toggleArrow(from: 3, to: 59, color: "G") // d1→d8
                    session.toggleSquareHighlight(57, color: "R") // b8
                    session.toggleSquareHighlight(51, color: "Y") // d7
                }
            }
            // dev hook: open the setup-position sheet (screenshots)
            if ProcessInfo.processInfo.environment["DCS_AUTO_SETUP"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showSetupSheet = true
                }
            }
            // dev hook: flip the board (screenshots)
            if ProcessInfo.processInfo.environment["DCS_AUTO_FLIP"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    session.toggleFlip()
                }
            }
            // dev hook: exercise M5 annotations (screenshots)
            if ProcessInfo.processInfo.environment["DCS_AUTO_M5"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    session.toEnd()
                    session.applyNag(1) // "!"
                    session.applyNag(18) // "+−"
                    session.commentDraft = "Scholar's mate — cover f7 early!"
                    session.commitComment()
                    session.back()
                    session.openCommentEditor()
                }
            }
            // dev hooks: diagram + PDF; merge of the first two games
            if ProcessInfo.processInfo.environment["DCS_AUTO_DIAGRAM"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    session.toEnd()
                    session.back(); session.back(); session.back()
                    session.toggleDiagram()
                    GamePrinter.exportPdf(session, to: URL(fileURLWithPath: "/tmp/dcs-diagram.pdf"))
                    try? session.game.toPgn().write(toFile: "/tmp/dcs-diagram.pgn",
                                                    atomically: true, encoding: .utf8)
                }
            }
            if ProcessInfo.processInfo.environment["DCS_AUTO_MERGE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    mergeGames([1, 2])
                    try? session.game.toPgn().write(toFile: "/tmp/dcs-merge.pgn",
                                                    atomically: true, encoding: .utf8)
                }
            }
            // dev hook: whole-game analysis at the given depth, result PGN
            // written to DCS_AUTO_ANALYZE_OUT (stdout dies with pkill)
            if let depthText = ProcessInfo.processInfo.environment["DCS_AUTO_ANALYZE"],
               let depth = Int(depthText) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    Task {
                        var settings = AnalysisSettings()
                        settings.depth = depth
                        let env = ProcessInfo.processInfo.environment
                        if let side = env["DCS_AUTO_ANALYZE_SIDE"].flatMap(AnalysisSide.init(rawValue:)) {
                            settings.side = side
                        }
                        settings.variations = env["DCS_AUTO_ANALYZE_VARS"] != nil
                        let started = Date()
                        let n = await analyzer.run(session: session, settings: settings)
                        let out = ProcessInfo.processInfo.environment["DCS_AUTO_ANALYZE_OUT"]
                            ?? "/tmp/dcs-analyze.pgn"
                        let report = """
                        marks: \(n.map(String.init) ?? "nil")
                        summary: \(analyzer.summary ?? "-")
                        error: \(analyzer.errorText ?? "-")
                        seconds: \(Int(Date().timeIntervalSince(started)))

                        \(session.game.toPgn())
                        """
                        try? report.write(toFile: out, atomically: true, encoding: .utf8)
                    }
                }
            }
            // dev hook: open reference mode and step one move (screenshots)
            if ProcessInfo.processInfo.environment["DCS_AUTO_TREE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if let name = ProcessInfo.processInfo.environment["DCS_AUTO_TREE_SOURCE"],
                       let src = ReferenceSource(rawValue: name) {
                        tree.setSource(src)
                    }
                    tree.toggle(fen: session.fen)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if let sans = ProcessInfo.processInfo.environment["DCS_AUTO_TREE_PLAY"] {
                        session.toStart()    // e.g. "e4 e5 Ke2": a novelty at move 2
                        for san in sans.split(separator: " ") { session.play(san: String(san)) }
                    } else if ProcessInfo.processInfo.environment["DCS_AUTO_TREE_END"] != nil {
                        session.toEnd()      // a late move: never in any book
                    } else {
                        session.forward()
                    }
                }
            }
            // clicks steer the two-state focus: list zone → browse, game
            // zone → engaged (NSTextView/board don't hand focus back cleanly)
            mouseMonitor.install(matching: .leftMouseDown) { event in
                trackFocusClick(event)
                return false
            }
        }
        .onDisappear {
            keyMonitor.remove()
            mouseMonitor.remove()
            closeSaver.detach()
            engine.shutdown()
        }
        // a different list was opened: with rows, row 0 auto-loads; empty
        // (fresh PGN) → blank board, so no stale game lingers over it
        .onChange(of: store.generation) {
            tree.hide() // new list: reference mode starts over
            if store.gameCount == 0 { session.resetToBlank() }
        }
        .sheet(isPresented: $showSetupSheet) {
            SetupPositionSheet { fen in
                newGame(fen: fen)
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            GameInfoSheet(session: session,
                          listName: store.sourceName ?? "list") {
                if session.sourceGameId >= 0 {
                    // header edit of an existing game: save + write back
                    SavePrompt.save(session)
                } else if SavePrompt.appendNewGame(session) {
                    // the saved game is now the last row — select it
                    listController.select(id: session.sourceGameId)
                }
            }
        }
        .sheet(isPresented: $showAnalyzeSheet) {
            AnalyzeGameSheet(session: session, analyzer: analyzer) {
                // two engines on one game is one too many: the live panel
                // yields to the batch run (⌘E brings it back afterwards)
                if engine.panelVisible { toggleEngine() }
            }
        }
        .navigationTitle(store.sourceName ?? "DC Studio")
        .focusedSceneValue(\.windowActions, WindowActions(
            newGame: { newGame() },
            save: { saveGame() },
            gameInfo: { showSaveSheet = true },
            flip: { session.toggleFlip() },
            toggleEngine: { toggleEngine() },
            toggleReference: { toggleReference() },
            exportGame: { exportGamePgn(session) },
            focusSearch: { searchFocused = true },
            setupPosition: { showSetupSheet = true },
            clearAnnotations: { session.clearAnnotations() },
            analyzeGame: { showAnalyzeSheet = true },
            insertDiagram: { session.toggleDiagram() },
            printGame: { GamePrinter.print(session) },
            exportPdf: { GamePrinter.exportPdf(session) },
            mergeGames: { mergeGames(listController.selectedGameIds) }
        ))
        // drag .pgn files from Finder onto the window: each opens as a tab
        .dropDestination(for: URL.self) { urls, _ in
            let pgns = urls.filter { $0.pathExtension.lowercased() == "pgn" }
            guard !pgns.isEmpty else { return false }
            for url in pgns { FileOpener.shared.open(url) }
            return true
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open PGN", systemImage: "folder") { FileOpener.shared.chooseAndOpen() }
                .disabled(store.importing)
                .help("Open a PGN file — its games replace the current list")
                Button("New PGN", systemImage: "doc.badge.plus") { FileOpener.shared.createAndOpen() }
                .disabled(store.importing)
                .help("Create a new, empty PGN file and open it as the list")
                Button("New Game", systemImage: "plus.square") {
                    newGame()
                }
                .help("Start a new game on this board (⌘S saves it into the list)")
                Button("Setup", systemImage: "square.grid.3x3.square") {
                    showSetupSheet = true
                }
                .help("Compose a position and start a game from it (⌥⌘N)")
                Button("Save", systemImage: "square.and.arrow.down") {
                    saveGame()
                }
                .disabled(!store.canWriteBack)
                .help("Save this game into the open list and its PGN file (⌘S)")
                Button("Game Info", systemImage: "square.and.pencil") {
                    showSaveSheet = true
                }
                .disabled(!store.canWriteBack)
                .help("Edit the game's players, result, event… (⌘I)")
                Button("Engine", systemImage: "cpu") {
                    toggleEngine()
                }
                .help("Show/hide engine analysis — visible means analyzing (⌘E)")
                Button("Reference", systemImage: "books.vertical") {
                    toggleReference()
                }
                .help("Opening reference: move stats here + list filtered to matching games (⌘T)")
                Spacer()
                Button("Start", systemImage: "backward.end") { session.toStart() }
                    .help("Go to the start of the game (Home)")
                Button("Back", systemImage: "chevron.backward") { session.back() }
                    .help("One move back (←)")
                Button("Forward", systemImage: "chevron.forward") { session.forward() }
                    .help("One move forward (→)")
                Button("End", systemImage: "forward.end") { session.toEnd() }
                    .help("Go to the end of the line (End)")
            }
        }
        .onDisappear {
            keyMonitor.remove()
            mouseMonitor.remove()
            closeSaver.detach()
            for o in keyObservers { NotificationCenter.default.removeObserver(o) }
            engine.shutdown()
            OpenStores.shared.unregister(store)
            if let url { FileOpener.shared.release(url) }
        }
        .frame(minWidth: 860, minHeight: 600)
    }

    /// The source file changed under us. Reload throws this cache away —
    /// including unsaved edits to this file's games — and takes the file as
    /// it is now; Keep Mine carries on, and the next save replaces the
    /// file (with a .pgn.bak kept).
    private var changedOnDiskBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("“\(store.sourceURL?.lastPathComponent ?? "This file")” was changed by another program.")
                .font(.system(size: 12))
            Spacer()
            Button("Reload") { store.reloadFromDisk() }
                .help("Take the file as it is on disk now. Unsaved edits to its games are lost.")
            Button("Keep Mine") { store.keepMine() }
                .help("Keep what this window has; the next save replaces the file (a .pgn.bak is kept).")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.18))
    }

    /// Copy to ▸ another open file: whole games, duplicates (same moves)
    /// skipped, the target written back once. Both tabs say what happened.
    private func copyGames(_ ids: [Int64], to target: DatabaseStore) {
        let pgns = ids.compactMap { store.pgn(for: $0) }
        guard !pgns.isEmpty else { return }
        do {
            let r = try target.copyGames(pgns)
            let what = r.duplicates == 0
                ? "\(r.copied) game\(r.copied == 1 ? "" : "s")"
                : "\(r.copied) game\(r.copied == 1 ? "" : "s") (\(r.duplicates) already there)"
            store.setStatus("copied \(what) to “\(target.sourceName ?? "?")”")
            target.setStatus("\(what) copied in from “\(store.sourceName ?? "?")”")
        } catch {
            store.setStatus("copy failed: \(error.localizedDescription)")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search White, Black or Event (⌘F)", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand {
                    searchQuery = ""
                    searchFocused = false
                }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Button {
                showFilters.toggle()
            } label: {
                Image(systemName: headerFilterActive
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(headerFilterActive ? Color.accentColor : .secondary)
            .help("Filter by result, date and Elo")
            .popover(isPresented: $showFilters, arrowEdge: .bottom) { filterPopover }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .onChange(of: searchQuery) { store.setSearch(searchQuery) }
    }

    private var headerFilterActive: Bool {
        store.filter.result != nil || store.filter.dateFrom != nil
            || store.filter.dateTo != nil || store.filter.minElo != nil
            || store.filter.maxElo != nil
    }

    /// Header criteria. Applied on every edit (the list is a live view of
    /// the filter, like the search field), cleared with one button.
    private var filterPopover: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Result").gridColumnAlignment(.trailing)
                Picker("", selection: $filterResult) {
                    Text("Any").tag("")
                    Text("1-0").tag("1-0")
                    Text("½-½").tag("1/2-1/2")
                    Text("0-1").tag("0-1")
                    Text("*").tag("*")
                }
                .labelsHidden()
                .frame(width: 120)
            }
            GridRow {
                Text("Date")
                HStack(spacing: 4) {
                    TextField("from YYYY.MM.DD", text: $filterDateFrom).frame(width: 118)
                    Text("–")
                    TextField("to", text: $filterDateTo).frame(width: 118)
                }
            }
            GridRow {
                Text("Elo")
                HStack(spacing: 4) {
                    TextField("min", text: $filterMinElo).frame(width: 60)
                    Text("–")
                    TextField("max", text: $filterMaxElo).frame(width: 60)
                    Text("both players").foregroundStyle(.secondary).font(.caption)
                }
            }
            GridRow {
                Text("")
                HStack {
                    Button("Clear") {
                        filterResult = ""; filterDateFrom = ""; filterDateTo = ""
                        filterMinElo = ""; filterMaxElo = ""
                    }
                    .disabled(!headerFilterActive)
                    Spacer()
                    Text("\(store.displayCount) of \(store.gameCount)")
                        .foregroundStyle(.secondary).font(.caption)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
        .padding(12)
        .frame(width: 330)
        .onChange(of: filterResult) { applyHeaderFilter() }
        .onChange(of: filterDateFrom) { applyHeaderFilter() }
        .onChange(of: filterDateTo) { applyHeaderFilter() }
        .onChange(of: filterMinElo) { applyHeaderFilter() }
        .onChange(of: filterMaxElo) { applyHeaderFilter() }
    }

    private func applyHeaderFilter() {
        store.setHeaderFilter(result: filterResult, dateFrom: filterDateFrom,
                              dateTo: filterDateTo,
                              minElo: UInt32(filterMinElo.trimmingCharacters(in: .whitespaces)),
                              maxElo: UInt32(filterMaxElo.trimmingCharacters(in: .whitespaces)))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(store.positionFilter != nil
                 ? "\(store.matchedCount) of \(store.gameCount) games reach this position"
                 : store.isFiltered
                     ? "\(store.displayCount) of \(store.gameCount) games match"
                     : "\(store.gameCount) games")
                .foregroundStyle(.secondary)
            if store.importing {
                ProgressView().controlSize(.small)
            }
            if let status = store.statusText {
                Text(status).foregroundStyle(.secondary)
            }
            if let error = store.errorText {
                Text(error).foregroundStyle(.red)
            }
            Spacer()
            Text(engaged ? "Esc back to list · ⌥↑↓ switch game"
                         : "↑↓ select · ←→ step moves · Enter open · double-click info · ⌘double-click new window")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // MARK: two-state focus

    private func setEngaged(_ value: Bool) {
        engaged = value
        if value {
            hostWindow?.makeFirstResponder(nil)
        } else {
            listController.focusTable()
        }
    }

    /// Clicks in the list zone browse; clicks anywhere else engage.
    private func trackFocusClick(_ event: NSEvent) {
        guard event.window === hostWindow,
              let scrollView = listController.scrollView else { return }
        let listRect = scrollView.convert(scrollView.bounds, to: nil)
        let inList = listRect.contains(event.locationInWindow)
        if engaged == inList { setEngaged(!inList) }
    }

    // MARK: selection / saving

    private func loadSelected(_ id: Int64) {
        guard id != session.sourceGameId else { return }
        if let pgn = store.pgn(for: id) {
            session.loadPgn(pgn, sourceId: id)
            store.rememberSelected(id)
        }
    }

    /// Native tabs, and the engine yielding when the window is not key.
    private func attachWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "dcstudio-database"
        // SwiftUI has already shown the window on its own by the time we
        // get it, so joining the tab group is done by hand: into whichever
        // database window is in front (the restore sequence and ⌘O both
        // land here)
        if window.tabbedWindows == nil || window.tabbedWindows?.count == 1,
           let anchor = NSApp.windows.first(where: {
               $0 !== window && $0.isVisible && $0.tabbingIdentifier == "dcstudio-database"
           }) {
            anchor.addTabbedWindow(window, ordered: .above)
        }
        for o in keyObservers { NotificationCenter.default.removeObserver(o) }
        let nc = NotificationCenter.default
        keyObservers = [
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                           queue: .main) { _ in MainActor.assumeIsolated { engine.suspend() } },
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                           queue: .main) { _ in MainActor.assumeIsolated { engine.resume() } },
        ]
        // the observers arrive a beat after the window does; a window that
        // has already been pushed behind another by then must not keep
        // searching as if it were in front
        if !window.isKeyWindow { engine.suspend() }
    }

    /// "+" opened this window empty: offer a file; nothing chosen, no window.
    private func askForFile() {
        wantsFile = false
        AppDelegate.trace("empty window from +: asking for a file")
        let chosen: [URL]
        if ProcessInfo.processInfo.environment["DCS_AUTO_PLUS_CANCEL"] != nil {
            chosen = []                                       // the test's Cancel
        } else if let pick = ProcessInfo.processInfo.environment["DCS_AUTO_PLUS_PICK"] {
            chosen = [URL(fileURLWithPath: pick)]             // the test's Open
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "pgn") ?? .plainText, .plainText]
            panel.allowsMultipleSelection = true
            panel.message = "Choose a PGN file for this tab."
            chosen = panel.runModal() == .OK ? panel.urls : []
        }
        guard let first = chosen.first else {
            hostWindow?.close()
            return
        }
        if let open = OpenStores.shared.store(for: first) {
            // already open elsewhere: that tab comes forward, this one goes
            open.bringWindowForward()
            hostWindow?.close()
        } else if FileOpener.shared.claim(first) {
            url = DatabaseStore.canonical(first)
        } else {
            hostWindow?.close()
        }
        for more in chosen.dropFirst() { FileOpener.shared.open(more) }
    }

    /// The files open last time come back as tabs — the first into this
    /// window (SwiftUI opened it empty), the rest through the opener.
    private func restoreIfFirst() {
        guard !Self.restored else { return }
        Self.restored = true
        guard url == nil,
              ProcessInfo.processInfo.environment["DCS_AUTO_OPEN"] == nil else { return }
        let files = AppSettings.shared.openFiles
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = files.first, FileOpener.shared.claim(first) else { return }
        url = DatabaseStore.canonical(first)
        for more in files.dropFirst() { FileOpener.shared.open(more) }
    }

    private func confirmLeaveGame() -> Bool {
        SavePrompt.run(for: session, canCancel: true)
    }

    private func toggleEngine() {
        if tree.visible { tree.hide() } // the two share the panel
        engine.togglePanel(target: session.highlightedFen)
    }

    private func toggleReference() {
        if engine.panelVisible { // the two share the panel
            engine.togglePanel(target: session.highlightedFen)
        }
        tree.toggle(fen: session.fen, parentFen: session.parentFen, san: session.currentSan)
    }

    /// "+": a blank board right here — no extra window. The list selection
    /// clears (this game isn't in the list yet) and the board takes focus.
    /// With a `fen`, the scratch game starts from that position (Setup).
    private func newGame(fen: String? = nil) {
        guard confirmLeaveGame() else { return }
        listController.deselect()
        if let fen {
            session.loadPgn("[SetUp \"1\"]\n[FEN \"\(fen)\"]\n\n*")
        } else {
            session.resetToBlank()
        }
        setEngaged(true)
    }

    /// Merge Selected Games: the first game's tree takes the others as
    /// variations (Rust `merge_pgn`), and the result opens as a new,
    /// unsaved game — ⌘S appends it to the file. The originals stay put.
    private func mergeGames(_ ids: [Int64]) {
        guard ids.count >= 2, confirmLeaveGame() else { return }
        let pgns = ids.compactMap { store.pgn(for: $0) }
        guard let first = pgns.first, let merged = try? Game.fromPgn(pgn: first) else { return }
        var added: UInt32 = 0
        var skipped = 0
        for pgn in pgns.dropFirst() {
            if let n = try? merged.mergePgn(pgn: pgn) { added += n } else { skipped += 1 }
        }
        merged.setHeader(key: "Event", value: "Merged: \(pgns.count) games")
        merged.setHeader(key: "Result", value: "*")
        listController.deselect()
        session.loadPgn(merged.toPgn())
        setEngaged(true)
        store.setStatus(skipped == 0
            ? "merged \(pgns.count) games, \(added) moves added"
            : "merged \(pgns.count - skipped) games (\(skipped) skipped: different start position)")
    }

    /// ⌘S — same flow as the standalone window: existing games update in
    /// place, a newly entered game gets the save mask, then is appended.
    private func saveGame() {
        if session.sourceGameId >= 0 {
            SavePrompt.save(session)
        } else if session.hasMoves {
            showSaveSheet = true
        }
    }

    // MARK: keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        if ProcessInfo.processInfo.environment["DCS_KEY_DEBUG"] != nil {
            print("keyDown code=\(event.keyCode) engaged=\(engaged) window=\(event.window === hostWindow)")
        }
        guard event.window === hostWindow else { return false }
        // leave keys alone while typing (comment popover in M5, importer, …)
        if let text = hostWindow?.firstResponder as? NSTextView, text.isEditable { return false }

        // ⌥↑↓ switch games in either state (⌘↑ is reserved by
        // NOTATION-VIEW.md for M5's promote-variation)
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods == .option {
            switch event.keyCode {
            case 126: // ⌥↑ previous game
                if confirmLeaveGame() { listController.selectRelative(-1) }
                return true
            case 125: // ⌥↓ next game
                if confirmLeaveGame() { listController.selectRelative(1) }
                return true
            default:
                break
            }
        }
        // ⌘Z / ⇧⌘Z — game-edit undo/redo, either state
        if event.keyCode == 6, mods == .command { // z
            if event.modifierFlags.contains(.shift) {
                session.redo()
            } else {
                session.undo()
            }
            return true
        }
        // engaged-only editing chords (per NOTATION-VIEW.md)
        if mods == .command, engaged {
            switch event.keyCode {
            case 126: // ⌘↑ promote variation
                session.promoteCurrentVariation()
                return true
            case 0: // ⌘A comment editor
                guard session.currentNode != 0 else { break }
                session.openCommentEditor()
                return true
            default:
                break
            }
        }
        guard mods.isEmpty else { return false }

        // the branch-point popup owns its keys in either state
        if session.variationChoices != nil {
            return handleGameKey(event, session: session)
        }

        if engaged {
            if handleGameKey(event, session: session) { return true }
            if event.keyCode == 53 { // esc, nothing else consumed it
                setEngaged(false)
                return true
            }
            return false
        }

        // browse: the table keeps ↑↓ (native selection); we take ←→ + Enter
        switch event.keyCode {
        case 123: session.back(); return true
        case 124: session.forward(); return true
        case 36, 76: setEngaged(true); return true
        case 51: // ⌫ — delete the selected game (confirmed)
            deleteSelectedGame()
            return true
        default:
            if event.charactersIgnoringModifiers == "f" {
                session.toggleFlip()
                return true
            }
            return false
        }
    }

    /// Deletes the list-selected game after confirmation (writes back).
    private func deleteSelectedGame() {
        if let id = listController.selectedGameId { confirmAndDelete(id) }
    }

    private func confirmAndDelete(_ id: Int64) {
        guard store.canWriteBack else { return }
        let alert = NSAlert()
        alert.messageText = "Delete game #\(id)?"
        alert.informativeText = "Removes the game from the list and its PGN file."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let wasCurrent = session.sourceGameId == id
        if wasCurrent { session.detachFromDatabase() }
        store.deleteGame(id: id)
        if wasCurrent { session.resetToBlank() }
    }
}
