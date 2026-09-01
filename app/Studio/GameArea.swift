import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(DanceChessCore)
import DanceChessCore
#endif

/// Board + notation (+ engine, when its panel is open) for one game
/// session — shared by the main window's top pane and the standalone
/// GameWindow. Layout per the 2026-09-01 design: eval bar is a horizontal
/// strip under the board, engine lines live below the notation.
struct GameArea: View {
    let session: GameSession
    let engine: EngineSession
    /// Reference mode (main window only; nil in the standalone window).
    var tree: OpeningTreeModel? = nil

    private var bottomPanelVisible: Bool {
        engine.panelVisible || (tree?.visible ?? false)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                BoardView(session: session)
                    .overlay {
                        if let choices = session.variationChoices {
                            VariationPicker(session: session, choices: choices)
                        }
                    }
                if engine.panelVisible {
                    EvalBar(whiteCp: engine.whiteEval,
                            scoreText: engine.lines.first?.scoreText)
                }
                if let error = session.errorText {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .padding(12)
            .frame(minWidth: 360, minHeight: 360)

            VStack(alignment: .leading, spacing: 0) {
                Text(session.gameTitle)
                    .font(.headline)
                    .padding(10)
                Divider()
                if bottomPanelVisible {
                    VSplitView {
                        NotationView(session: session)
                            .frame(minHeight: 120)
                        if engine.panelVisible {
                            EnginePanel(engine: engine, session: session)
                                .frame(minHeight: 90, idealHeight: 140)
                        } else if let tree {
                            OpeningTreePanel(tree: tree, session: session)
                                .frame(minHeight: 90, idealHeight: 160)
                        }
                    }
                } else {
                    NotationView(session: session)
                }
            }
            .frame(minWidth: 280)
        }
        .overlay {
            if session.commentEditorOpen {
                CommentEditor(session: session)
            }
        }
        .onChange(of: session.fen) {
            engine.updatePosition(fen: session.highlightedFen)
            tree?.update(fen: session.fen) // root included: first-move stats
        }
    }
}

/// Comment popover (per NOTATION-VIEW.md: comments are never edited inline
/// in the notation text — plain TextEditor, written back on save).
struct CommentEditor: View {
    @Bindable var session: GameSession

    var body: some View {
        ZStack {
            // backdrop: clicking outside cancels
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { session.cancelComment() }
            VStack(alignment: .leading, spacing: 8) {
                Text("Comment on \(session.currentMoveLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { session.commentDraft ?? "" },
                    set: { session.commentDraft = $0 }
                ))
                .font(.system(size: 13))
                .frame(width: 340, height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.4)))
                HStack {
                    Spacer()
                    Button("Cancel") { session.cancelComment() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { session.commitComment() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("⌘↩")
                }
            }
            .padding(12)
            .frame(width: 372) // keep the card compact (Spacer would stretch it)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8)
        }
    }
}

/// Save-panel export of the current game (menu bar + notation context menu).
@MainActor
func exportGamePgn(_ session: GameSession) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "pgn") ?? .plainText]
    let white = session.game.header(key: "White") ?? "game"
    let black = session.game.header(key: "Black") ?? ""
    panel.nameFieldStringValue = black.isEmpty ? "\(white).pgn" : "\(white) - \(black).pgn"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        try session.game.toPgn().write(to: url, atomically: true, encoding: .utf8)
    } catch {
        session.errorText = "Export failed: \(error.localizedDescription)"
    }
}

/// Destructive-edit confirmation, then deletes from the current move on.
@MainActor
func confirmDeleteCurrent(_ session: GameSession) {
    guard session.currentNode != 0 else { return }
    let alert = NSAlert()
    alert.messageText = "Delete from \(session.currentMoveLabel)?"
    alert.informativeText = "Removes this move and everything after it (including variations)."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
        session.deleteCurrentSubtree()
    }
}

/// The in-game key table from NOTATION-VIEW.md (arrows, picker, Home/End).
/// Callers have already applied their window/modifier/text-editing guards.
/// Returns true when the event was consumed; an unconsumed Esc is the
/// caller's chance to leave the game (browse mode in the main window).
@MainActor
func handleGameKey(_ event: NSEvent, session: GameSession) -> Bool {
    let picking = session.variationChoices != nil
    switch event.keyCode {
    case 123: // ←
        if picking { session.variationCancel() } else { session.back() }
    case 124: // →
        if picking { session.variationConfirm() } else { session.forward() }
    case 126: // ↑
        if picking { session.variationStep(-1) } else { session.previousLine() }
    case 125: // ↓
        if picking { session.variationStep(1) } else { session.nextLine() }
    case 36, 76: // return: confirm in the picker, else comment editor (M5)
        if picking {
            session.variationConfirm()
        } else if session.currentNode != 0 {
            session.openCommentEditor()
        } else {
            return false
        }
    case 53: // esc
        if picking {
            session.variationCancel()
        } else if session.pendingPromotion != nil {
            session.cancelPromotion()
        } else {
            return false
        }
    case 115: session.toStart() // home (fn+←)
    case 119: session.toEnd() // end (fn+→)
    case 51: // ⌫ — delete from here (confirmed)
        guard session.currentNode != 0 else { return false }
        confirmDeleteCurrent(session)
    default:
        // NAG keys per NOTATION-VIEW.md ("!" "?" — same key toggles off)
        switch event.charactersIgnoringModifiers {
        case "!": session.applyNag(1)
        case "?": session.applyNag(2)
        case "f": session.toggleFlip()
        default: return false
        }
    }
    return true
}

/// Save prompt for one modified database game. Used when leaving a game in
/// the main window (with Cancel) and when a window closes (no Cancel — the
/// close cannot be stopped from willClose, only the changes rescued).
@MainActor
enum SavePrompt {
    /// Set when quit-time saving already ran, so per-window willClose
    /// savers don't prompt a second time.
    static var suppressPrompts = false

    /// Returns false when the user cancelled (only possible with `canCancel`).
    @discardableResult
    static func run(for session: GameSession, canCancel: Bool) -> Bool {
        guard !suppressPrompts else { return true }
        let isNewGame = session.sourceGameId < 0
        if isNewGame {
            // scratch entry: worth rescuing only if it has moves and a
            // single-file list to land in
            guard session.hasMoves, DatabaseStore.shared.canWriteBack else { return true }
        } else {
            guard session.isModified else { return true }
        }
        let alert = NSAlert()
        alert.messageText = "Unsaved Changes"
        alert.informativeText = isNewGame
            ? "Save this new game into “\(DatabaseStore.shared.sourceName ?? "the list")”?"
            : "Save the changes to “\(session.gameTitle)” to the database?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        if canCancel { alert.addButton(withTitle: "Cancel") }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return isNewGame ? appendNewGame(session) : save(session)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    @discardableResult
    static func save(_ session: GameSession) -> Bool {
        do {
            try DatabaseStore.shared.updateGame(id: session.sourceGameId,
                                                pgn: session.game.toPgn())
            session.markSaved()
            return true
        } catch {
            session.errorText = "Save failed: \(error)"
            return false
        }
    }

    /// Appends a newly entered (scratch) game to the open list + PGN file.
    @discardableResult
    static func appendNewGame(_ session: GameSession) -> Bool {
        do {
            let id = try DatabaseStore.shared.addGame(pgn: session.game.toPgn())
            session.attachToDatabase(id: id)
            return true
        } catch {
            session.errorText = "Save failed: \(error)"
            return false
        }
    }
}

/// Rescues unsaved changes when a game-hosting window closes.
@MainActor
final class WindowCloseSaver {
    private var observer: NSObjectProtocol?

    func attach(window: NSWindow?, session: GameSession) {
        detach()
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                _ = SavePrompt.run(for: session, canCancel: false)
            }
        }
    }

    func detach() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
