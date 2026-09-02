import AppKit
import SwiftUI

/// Per-window actions surfaced to the menu bar (nil = item disabled).
/// Always-equal so SwiftUI doesn't churn on every body evaluation — the
/// closures read live @State storage regardless.
struct WindowActions: Equatable {
    var openPgn: (() -> Void)?
    var newPgnFile: (() -> Void)?
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
    var openRecent: ((String) -> Void)?
    var clearRecents: (() -> Void)?
    var recentFiles: [String] = []

    // recents are the only data the menu renders; closures read live state
    static func == (lhs: WindowActions, rhs: WindowActions) -> Bool {
        lhs.recentFiles == rhs.recentFiles
    }
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Game") { actions?.newGame?() }
                .keyboardShortcut("n")
                .disabled(actions?.newGame == nil)
            Button("New PGN File…") { actions?.newPgnFile?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.newPgnFile == nil)
            Button("Open PGN…") { actions?.openPgn?() }
                .keyboardShortcut("o")
                .disabled(actions?.openPgn == nil)
            Menu("Open Recent") {
                ForEach(actions?.recentFiles ?? [], id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        actions?.openRecent?(path)
                    }
                }
                if !(actions?.recentFiles ?? []).isEmpty {
                    Divider()
                    Button("Clear Menu") { actions?.clearRecents?() }
                }
            }
            .disabled((actions?.recentFiles ?? []).isEmpty)
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
        }
        CommandMenu("Game") {
            Button("Setup Position…") { actions?.setupPosition?() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(actions?.setupPosition == nil)
            Button("Clear Arrows & Highlights") { actions?.clearAnnotations?() }
                .disabled(actions?.clearAnnotations == nil)
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

    /// Finder / Dock hand-off (.pgn association, drag onto the Dock icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            let pgns = urls.filter { $0.pathExtension.lowercased() == "pgn" }
            guard !pgns.isEmpty else { return }
            // unsaved edits die with the replaced list — same gate as Open
            for session in GameSession.SessionRegistry.shared.modified {
                guard SavePrompt.run(for: session, canCancel: true) else { return }
            }
            DatabaseStore.shared.openPgn(pgns)
        }
    }

    /// Quit-time rescue for unsaved database games (one alert for all of
    /// them; each window's own willClose saver is suppressed afterwards).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
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
}

@main
struct StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // single main window: board + notation on top, game list below
        WindowGroup {
            MainWindow()
        }
        .commands { StudioCommands() }
        // standalone game windows (⌘-double-click / 新对局); -1 = blank board
        WindowGroup(id: "game", for: Int64.self) { $gameId in
            GameWindow(gameId: gameId)
        } defaultValue: {
            -1
        }
    }
}
