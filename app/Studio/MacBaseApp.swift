import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Per-window actions surfaced to the menu bar (nil = item disabled).
/// Always-equal so SwiftUI doesn't churn on every body evaluation — the
/// closures read live @State storage regardless.
struct WindowActions: Equatable {
    var newGame: (() -> Void)?
    var save: (() -> Void)?
    var gameInfo: (() -> Void)?
    var flip: (() -> Void)?
    var toggleEngine: (() -> Void)?
    var toggleReference: (() -> Void)?
    var exportGame: (() -> Void)?
    var focusSearch: (() -> Void)?
    var setupPosition: (() -> Void)?
    var clearAnnotations: (() -> Void)?
    var analyzeGame: (() -> Void)?
    var insertDiagram: (() -> Void)?
    var printGame: (() -> Void)?
    var exportPdf: (() -> Void)?
    var mergeGames: (() -> Void)?

    // nothing here is rendered; the closures read live state
    static func == (lhs: WindowActions, rhs: WindowActions) -> Bool { true }
}

struct WindowActionsKey: FocusedValueKey {
    typealias Value = WindowActions
}

extension FocusedValues {
    var windowActions: WindowActions? {
        get { self[WindowActionsKey.self] }
        set { self[WindowActionsKey.self] = newValue }
    }
}

/// Menu bar (standard Mac experience per NOTATION-VIEW.md): shortcuts for
/// discrete commands live here; navigation/annotation keys stay in the
/// per-window event monitor.
struct StudioCommands: Commands {
    @FocusedValue(\.windowActions) private var actions
    private var settings: AppSettings { AppSettings.shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Game") { actions?.newGame?() }
                .keyboardShortcut("n")
                .disabled(actions?.newGame == nil)
            Button("New PGN File…") { FileOpener.shared.createAndOpen() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open PGN…") { FileOpener.shared.chooseAndOpen() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(settings.recentFiles, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        FileOpener.shared.open(URL(fileURLWithPath: path))
                    }
                }
                if !settings.recentFiles.isEmpty {
                    Divider()
                    Button("Clear Menu") { settings.clearRecents() }
                }
            }
            .disabled(settings.recentFiles.isEmpty)
        }
        // NB: `replacing: .saveItem` would be a silent no-op — a non-document
        // File menu has no Save group to replace — so append instead.
        CommandGroup(after: .newItem) {
            Divider()
            Button("Save Game") { actions?.save?() }
                .keyboardShortcut("s")
                .disabled(actions?.save == nil)
            Button("Game Info…") { actions?.gameInfo?() }
                .keyboardShortcut("i")
                .disabled(actions?.gameInfo == nil)
            Button("Export Game as PGN…") { actions?.exportGame?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.exportGame == nil)
            Button("Export Game as PDF…") { actions?.exportPdf?() }
                .disabled(actions?.exportPdf == nil)
            Divider()
            Button("Print Game…") { actions?.printGame?() }
                .keyboardShortcut("p")
                .disabled(actions?.printGame == nil)
        }
        CommandMenu("Game") {
            Button("Setup Position…") { actions?.setupPosition?() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(actions?.setupPosition == nil)
            Button("Clear Arrows & Highlights") { actions?.clearAnnotations?() }
                .disabled(actions?.clearAnnotations == nil)
            Button("Insert Diagram") { actions?.insertDiagram?() }
                .keyboardShortcut("d")
                .disabled(actions?.insertDiagram == nil)
            Toggle("Figurine Notation", isOn: Binding(
                get: { AppSettings.shared.figurines },
                set: { AppSettings.shared.figurines = $0 }))
            Button("Merge Selected Games") { actions?.mergeGames?() }
                .disabled(actions?.mergeGames == nil)
            Divider()
            Button("Flip Board") { actions?.flip?() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(actions?.flip == nil)
            Button("Find in List") { actions?.focusSearch?() }
                .keyboardShortcut("f")
                .disabled(actions?.focusSearch == nil)
            Divider()
            Button("Engine Analysis") { actions?.toggleEngine?() }
                .keyboardShortcut("e")
                .disabled(actions?.toggleEngine == nil)
            Button("Opening Reference") { actions?.toggleReference?() }
                .keyboardShortcut("t")
                .disabled(actions?.toggleReference == nil)
            Button("Analyze Game…") { actions?.analyzeGame?() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(actions?.analyzeGame == nil)
        }
    }
}

/// Forces activation so keyboard focus lands on us even when launched as a
/// bare executable (`swift run StudioApp`, no bundle): otherwise the window
/// floats on top but the terminal keeps receiving the key presses.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Finder / Dock hand-off (.pgn association, drag onto the Dock icon):
    /// each file is a tab; one already open just comes forward.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.pathExtension.lowercased() == "pgn" {
                FileOpener.shared.open(url)
            }
        }
    }

    /// Quit-time rescue for unsaved database games (one alert for all of
    /// them; each window's own willClose saver is suppressed afterwards).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            Self.trace("shouldTerminate")
            // what is open now is what comes back next time; the windows
            // closing after this must not edit the list
            OpenStores.shared.freezeForQuit()
            let dirty = GameSession.SessionRegistry.shared.modified
            guard !dirty.isEmpty else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = dirty.count == 1
                ? "1 game has unsaved changes"
                : "\(dirty.count) games have unsaved changes"
            alert.informativeText = "Save the changes to the database before quitting?"
            alert.addButton(withTitle: "Save All and Quit")
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                for session in dirty { SavePrompt.save(session) }
                SavePrompt.suppressPrompts = true
                return .terminateNow
            case .alertSecondButtonReturn:
                SavePrompt.suppressPrompts = true
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.trace("willFinishLaunching")
        // dev hook: a real quit (⌘Q path) after N seconds, so a test can
        // exercise the restore list the way a user's session ends
        if let secs = ProcessInfo.processInfo.environment["DCS_AUTO_QUIT"].flatMap(Double.init) {
            Self.trace("auto-quit armed \(secs)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                Self.trace("terminate requested")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.trace("willTerminate")
    }

    /// DCS_TRACE=<file>: lifecycle breadcrumbs (stdout dies with the process).
    static func trace(_ what: String) {
        guard let path = ProcessInfo.processInfo.environment["DCS_TRACE"] else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data((what + "\n").utf8)); h.closeFile()
        } else {
            try? (what + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

@main
struct StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // one window per PGN file — board + notation on top, that file's
        // game list below. Windows tab together (native macOS tabs); a file
        // is opened once, and opening it again brings its window forward.
        WindowGroup(for: URL.self) { $url in
            MainWindow(url: $url)
        }
        .commands { StudioCommands() }
        // standalone game windows (⌘-double-click): a game out of one of
        // the open files, or a blank board
        WindowGroup(id: "game", for: GameRef.self) { $ref in
            GameWindow(ref: ref ?? GameRef(path: nil, id: -1))
        }
    }
}

/// A game in a file: what a standalone game window is opened with.
struct GameRef: Codable, Hashable {
    /// Path of the file's window; nil = a scratch board with no file.
    var path: String?
    var id: Int64
}

/// Opens files as windows/tabs from places that have no SwiftUI
/// environment — the app delegate, the tab bar's "+", the standalone game
/// window. The first main window hands over `openWindow`; until then
/// requests queue and are replayed when it appears.
@MainActor
final class FileOpener {
    static let shared = FileOpener()
    private var opener: ((URL) -> Void)?
    private var pending: [URL] = []
    /// Files a window has been assigned, whether or not its store has
    /// loaded yet. The registry of stores is not enough: SwiftUI applies a
    /// window's value on the next update pass, and two opens of one file
    /// in the same turn would both see an empty registry and both open.
    private var claimed: Set<URL> = []

    func install(_ open: @escaping (URL) -> Void) {
        opener = open
        let queued = pending
        pending = []
        for url in queued { self.open(url) }
    }

    /// Marks `url` as taken by a window. False if it already was.
    @discardableResult
    func claim(_ url: URL) -> Bool {
        claimed.insert(DatabaseStore.canonical(url)).inserted
    }

    func release(_ url: URL) {
        claimed.remove(DatabaseStore.canonical(url))
    }

    /// One file, one window: an open file's window comes forward instead.
    func open(_ url: URL) {
        let url = DatabaseStore.canonical(url)
        if let existing = OpenStores.shared.store(for: url) {
            existing.bringWindowForward()
            return
        }
        guard claim(url) else { return } // a window is on its way to it
        if let opener { opener(url) } else { pending.append(url) }
    }

    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "pgn") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = true
        panel.message = "Each file opens in its own tab."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    func createAndOpen() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "pgn") ?? .plainText]
        panel.nameFieldStringValue = "games.pgn"
        panel.message = "Create a new, empty PGN file; it opens as a tab and games you enter are saved into it."
        panel.prompt = "Create"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DatabaseStore.createEmptyPgn(at: url)
            open(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
