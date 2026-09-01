import SwiftUI
import UniformTypeIdentifiers
#if canImport(MacBaseCore)
import MacBaseCore
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
    @State private var store = DatabaseStore.shared
    @State private var session = GameSession()
    @State private var engine = EngineSession()
    @State private var tree = OpeningTreeModel()
    @State private var engaged = false
    @State private var listController = GameListController()
    @State private var keyMonitor = KeyEventMonitor()
    @State private var mouseMonitor = KeyEventMonitor()
    @State private var closeSaver = WindowCloseSaver()
    @State private var hostWindow: NSWindow?
    @State private var showImporter = false
    @State private var showSaveSheet = false
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
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
                            openWindow(id: "game", value: id)
                        } else if store.canWriteBack {
                            // the row is already selected & loaded — edit it
                            showSaveSheet = true
                        } else {
                            setEngaged(true)
                        }
                    },
                    onDeleteRequest: { confirmAndDelete($0) }
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
            }
        })
        .onAppear {
            keyMonitor.install { handleKey($0) }
            // dev hook (like MACBASE_KEY_DEBUG): open the engine panel on
            // launch and jump to the game's end so smoke runs can screenshot
            // live analysis without pressing ⌘E (engine idles at the root)
            if ProcessInfo.processInfo.environment["MACBASE_AUTO_ENGINE"] != nil {
                engine.togglePanel(target: session.highlightedFen)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    session.toEnd()
                }
            }
            // dev hook: open a PGN on launch (exercises the cache path
            // end-to-end without driving the file dialog)
            if let path = ProcessInfo.processInfo.environment["MACBASE_AUTO_OPEN"] {
                store.openPgn([URL(fileURLWithPath: path)])
            }
            // dev hook: pop the game-info sheet (layout screenshots)
            if ProcessInfo.processInfo.environment["MACBASE_AUTO_INFO"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showSaveSheet = true
                }
            }
            // dev hook: dump the menu bar to a file (wiring verification)
            if let path = ProcessInfo.processInfo.environment["MACBASE_DEBUG_MENU"] {
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
            if ProcessInfo.processInfo.environment["MACBASE_AUTO_MPV"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    engine.setMultiPV(engine.multiPV + 1)
                }
            }
            // dev hook: flip the board (screenshots)
            if ProcessInfo.processInfo.environment["MACBASE_AUTO_FLIP"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    session.toggleFlip()
                }
            }
            // dev hook: exercise M5 annotations (screenshots)
            if ProcessInfo.processInfo.environment["MACBASE_AUTO_M5"] != nil {
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
            // dev hook: open reference mode and step one move (screenshots)
            if ProcessInfo.processInfo.environment["MACBASE_AUTO_TREE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    tree.toggle(fen: session.fen)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    session.forward()
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
        .navigationTitle(store.sourceName.map { "MacBase — \($0)" } ?? "MacBase")
        .focusedSceneValue(\.windowActions, WindowActions(
            openPgn: { showImporter = true },
            newPgnFile: { newPgnFile() },
            newGame: { newGame() },
            save: { saveGame() },
            gameInfo: { showSaveSheet = true },
            flip: { session.toggleFlip() },
            toggleEngine: { toggleEngine() },
            toggleReference: { toggleReference() },
            exportGame: { exportGamePgn(session) },
            focusSearch: { searchFocused = true },
            openRecent: { path in
                guard confirmLeaveGame() else { return }
                store.openPgn([URL(fileURLWithPath: path)])
            },
            clearRecents: { store.clearRecents() },
            recentFiles: store.recentFiles
        ))
        // drag a .pgn from Finder onto the window to open it
        .dropDestination(for: URL.self) { urls, _ in
            let pgns = urls.filter { $0.pathExtension.lowercased() == "pgn" }
            guard !pgns.isEmpty, confirmLeaveGame() else { return false }
            store.openPgn(pgns)
            return true
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open PGN", systemImage: "folder") {
                    showImporter = true
                }
                .disabled(store.importing)
                .help("Open a PGN file — its games replace the current list")
                Button("New PGN", systemImage: "doc.badge.plus") {
                    newPgnFile()
                }
                .disabled(store.importing)
                .help("Create a new, empty PGN file and open it as the list")
                Button("New Game", systemImage: "plus.square") {
                    newGame()
                }
                .help("Start a new game on this board (⌘S saves it into the list)")
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
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "pgn") ?? .plainText, .plainText],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                // unsaved edits die with the replaced list — offer to save
                guard confirmLeaveGame() else { return }
                store.openPgn(urls)
            }
        }
        .frame(minWidth: 860, minHeight: 600)
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
                .disabled(store.positionFilter != nil)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .onChange(of: searchQuery) { store.setSearch(searchQuery) }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(store.positionFilter != nil
                 ? "\(store.matchedCount) of \(store.gameCount) games reach this position"
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
            UserDefaults.standard.set(id, forKey: DatabaseStore.lastSelectedGameKey)
        }
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
        tree.toggle(fen: session.fen)
    }

    /// "+": a blank board right here — no extra window. The list selection
    /// clears (this game isn't in the list yet) and the board takes focus.
    private func newGame() {
        guard confirmLeaveGame() else { return }
        listController.deselect()
        session.resetToBlank()
        setEngaged(true)
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

    private func newPgnFile() {
        guard confirmLeaveGame() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pgn") ?? .plainText]
        panel.nameFieldStringValue = "games.pgn"
        panel.message = "Create a new, empty PGN file — it becomes the open list, and games you enter are saved into it."
        panel.prompt = "Create"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.createNewPgn(at: url)
    }

    // MARK: keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        if ProcessInfo.processInfo.environment["MACBASE_KEY_DEBUG"] != nil {
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
