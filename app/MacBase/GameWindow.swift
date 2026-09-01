import SwiftUI
import UniformTypeIdentifiers
#if canImport(MacBaseCore)
import MacBaseCore
#endif

/// Standalone game window (⌘-double-click from the list, or 新对局).
/// The single-window flow lives in MainWindow; this one keeps its own
/// Open/Paste PGN toolbar for scratch use.
struct GameWindow: View {
    /// A `games.id` from the default database, or -1 for a blank board.
    var gameId: Int64 = -1

    @State private var session = GameSession()
    @State private var engine = EngineSession()
    @State private var showImporter = false
    @State private var showSaveSheet = false
    @State private var keyMonitor = KeyEventMonitor()
    @State private var closeSaver = WindowCloseSaver()
    @State private var hostWindow: NSWindow?

    var body: some View {
        GameArea(session: session, engine: engine)
            // Keyboard: an AppKit local event monitor, not SwiftUI onKeyPress.
            // onKeyPress needs a .focusable() view to actually hold focus, which
            // silently breaks after any board click; the monitor sees every
            // keyDown of this app while our window is key.
            .background(WindowReader { window in
                if hostWindow !== window {
                    hostWindow = window
                    closeSaver.attach(window: window, session: session)
                }
            })
            .onAppear {
                keyMonitor.install { handleKey($0) }
                if gameId >= 0, let pgn = DatabaseStore.shared.pgn(for: gameId) {
                    session.loadPgn(pgn, sourceId: gameId)
                }
            }
            .onDisappear {
                keyMonitor.remove()
                closeSaver.detach()
                engine.shutdown()
            }
            .navigationTitle(session.gameTitle)
            .focusedSceneValue(\.windowActions, WindowActions(
                save: { saveGame() },
                gameInfo: { showSaveSheet = true },
                flip: { session.toggleFlip() },
                toggleEngine: { engine.togglePanel(target: session.highlightedFen) },
                exportGame: { exportGamePgn(session) }
            ))
            .toolbar {
                ToolbarItemGroup {
                    Button("Save", systemImage: "square.and.arrow.down") { saveGame() }
                        .disabled(!DatabaseStore.shared.canWriteBack)
                        .help("Save this game into the open list and its PGN file (⌘S)")
                    Button("Game Info", systemImage: "square.and.pencil") {
                        showSaveSheet = true
                    }
                    .disabled(!DatabaseStore.shared.canWriteBack)
                    .help("Edit the game's players, result, event… (⌘I)")
                    Button("Open PGN", systemImage: "folder") { showImporter = true }
                        .help("Load a PGN into this board (scratch, not the list)")
                    Button("Paste PGN", systemImage: "doc.on.clipboard") { pastePgn() }
                        .help("Load a PGN from the clipboard onto this board")
                    Button("Engine", systemImage: "cpu") {
                        engine.togglePanel(target: session.highlightedFen)
                    }
                    .help("Show/hide engine analysis — visible means analyzing (⌘E)")
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
                allowedContentTypes: [UTType(filenameExtension: "pgn") ?? .plainText, .plainText]
            ) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let pgn = try? String(contentsOf: url, encoding: .utf8) {
                    session.loadPgn(pgn)
                }
            }
            .sheet(isPresented: $showSaveSheet) {
                GameInfoSheet(session: session,
                              listName: DatabaseStore.shared.sourceName ?? "list") {
                    if session.sourceGameId >= 0 {
                        SavePrompt.save(session)
                    } else {
                        SavePrompt.appendNewGame(session)
                    }
                }
            }
            .frame(minWidth: 760, minHeight: 460)
    }

    /// ⌘S: existing games update in place; a new game gets the save mask
    /// first, then is appended to the open list and its PGN file.
    private func saveGame() {
        if session.sourceGameId >= 0 {
            SavePrompt.save(session)
        } else {
            showSaveSheet = true
        }
    }

    private func pastePgn() {
        if let pgn = NSPasteboard.general.string(forType: .string) {
            session.loadPgn(pgn)
        }
    }

    /// Returns true when the event was consumed (keys per NOTATION-VIEW.md).
    private func handleKey(_ event: NSEvent) -> Bool {
        if ProcessInfo.processInfo.environment["MACBASE_KEY_DEBUG"] != nil {
            print("keyDown code=\(event.keyCode) window=\(event.window === hostWindow)")
        }
        guard event.window === hostWindow else { return false }
        // leave keys alone while typing (comment popover, importer, …)
        if let text = hostWindow?.firstResponder as? NSTextView, text.isEditable { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if event.keyCode == 6, mods == .command { // ⌘Z / ⇧⌘Z
            if event.modifierFlags.contains(.shift) {
                session.redo()
            } else {
                session.undo()
            }
            return true
        }
        if mods == .command {
            switch event.keyCode {
            case 126: // ⌘↑ promote variation
                session.promoteCurrentVariation()
                return true
            case 0: // ⌘A comment editor
                if session.currentNode != 0 {
                    session.openCommentEditor()
                    return true
                }
            default:
                break
            }
        }
        guard mods.isEmpty else { return false }
        return handleGameKey(event, session: session)
    }
}

/// App-local event monitor; the handler returns true to swallow the event.
@MainActor
final class KeyEventMonitor {
    private var monitor: Any?

    func install(matching mask: NSEvent.EventTypeMask = .keyDown,
                 _ handler: @escaping (NSEvent) -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handler(event) ? nil : event
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Hands the hosting NSWindow to SwiftUI (to scope the key monitor per window).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReporterView {
        let view = WindowReporterView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowReporterView, context: Context) {
        view.onWindow = onWindow
    }
}

final class WindowReporterView: NSView {
    var onWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let window = window
        // defer: AppKit calls this mid-layout, inside SwiftUI's update pass
        DispatchQueue.main.async { [onWindow] in onWindow?(window) }
    }
}

/// ChessBase-style popup at a branch point: ↑↓ + Return to pick the
/// continuation, Esc / ← to cancel. First row is the mainline move.
struct VariationPicker: View {
    let session: GameSession
    let choices: [VariationChoice]

    var body: some View {
        ZStack {
            // backdrop: click anywhere outside the panel cancels
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { session.variationCancel() }
            VStack(alignment: .leading, spacing: 1) {
                Text("Variations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 3)
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    HStack {
                        Text(choice.label)
                            .font(.system(size: 13, weight: index == 0 ? .semibold : .regular))
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(minWidth: 110, alignment: .leading)
                    .background(
                        index == session.variationIndex ? Color.accentColor : .clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .foregroundStyle(index == session.variationIndex ? Color.white : .primary)
                    .contentShape(Rectangle())
                    .onTapGesture { session.chooseVariation(choice.id) }
                    .onHover { hovering in
                        if hovering { session.variationIndex = index }
                    }
                }
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8)
        }
    }
}
