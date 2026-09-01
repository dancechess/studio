import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(DanceChessCore)
import DanceChessCore
#endif

// Design: docs/NOTATION-VIEW.md. The token stream comes from Rust
// (Game.notationTokens()); this file only renders and hit-tests.

extension NSAttributedString.Key {
    /// UInt32 node id carried by every move/number/nag/comment run.
    static let dcsNode = NSAttributedString.Key("dcsNodeID")
}

struct NotationView: NSViewRepresentable {
    let session: GameSession

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NotationTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onNodeClick = { [weak session] node in
            Task { @MainActor in session?.select(node) }
        }
        textView.onContextMenu = { [weak coordinator = context.coordinator] node in
            coordinator?.contextMenu(for: node)
        }

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NotationTextView else { return }
        let coordinator = context.coordinator
        coordinator.session = session
        if coordinator.version != session.tokensVersion {
            coordinator.version = session.tokensVersion
            let (text, ranges) = Self.buildAttributed(session.tokens)
            coordinator.nodeRanges = ranges
            coordinator.highlighted = nil
            textView.textStorage?.setAttributedString(text)
        }
        coordinator.highlight(session.currentNode, in: textView)
    }

    @MainActor
    final class Coordinator: NSObject {
        var version = -1
        var nodeRanges: [UInt32: NSRange] = [:]
        var highlighted: NSRange?
        weak var session: GameSession?

        func highlight(_ node: UInt32, in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let target = nodeRanges[node]
            guard target != highlighted else { return }
            if let old = highlighted, old.upperBound <= storage.length {
                storage.removeAttribute(.backgroundColor, range: old)
            }
            if let new = target {
                storage.addAttribute(
                    .backgroundColor,
                    value: NSColor.selectedTextBackgroundColor,
                    range: new
                )
                textView.scrollRangeToVisible(new)
            }
            highlighted = target
        }

        // --- context menu (M5, per NOTATION-VIEW.md) ---

        func contextMenu(for node: UInt32?) -> NSMenu? {
            guard let session else { return nil }
            // act on the clicked move: select it first (board follows)
            if let node, node != 0 { session.select(node) }
            let editable = session.currentNode != 0

            let menu = NSMenu()
            menu.autoenablesItems = false
            func item(_ title: String, _ action: Selector,
                      enabled: Bool = true, tag: Int = 0) -> NSMenuItem {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.isEnabled = enabled
                item.tag = tag
                return item
            }

            menu.addItem(item("Promote Variation", #selector(menuPromote), enabled: editable))
            menu.addItem(item("Delete From Here…", #selector(menuDelete), enabled: editable))
            menu.addItem(item("Edit Comment…", #selector(menuComment), enabled: editable))
            menu.addItem(.separator())

            let nagMenu = NSMenu()
            for (title, tag) in [("!", 1), ("?", 2), ("!!", 3), ("??", 4), ("!?", 5), ("?!", 6)] {
                nagMenu.addItem(item(title, #selector(menuNag(_:)), enabled: editable, tag: tag))
            }
            nagMenu.addItem(.separator())
            for (title, tag) in [("=", 10), ("∞", 13), ("⩲", 14), ("⩱", 15),
                                 ("±", 16), ("∓", 17), ("+−", 18), ("−+", 19)] {
                nagMenu.addItem(item(title, #selector(menuNag(_:)), enabled: editable, tag: tag))
            }
            nagMenu.addItem(.separator())
            nagMenu.addItem(item("Clear NAGs", #selector(menuClearNags), enabled: editable))
            let annotate = NSMenuItem(title: "Annotate", action: nil, keyEquivalent: "")
            annotate.isEnabled = editable
            menu.addItem(annotate)
            menu.setSubmenu(nagMenu, for: annotate)

            menu.addItem(.separator())
            menu.addItem(item("Copy Game PGN", #selector(menuCopyPgn)))
            menu.addItem(item("Copy Position FEN", #selector(menuCopyFen)))
            menu.addItem(item("Export Game as PGN…", #selector(menuExport)))
            return menu
        }

        @objc private func menuPromote() { session?.promoteCurrentVariation() }
        @objc private func menuDelete() {
            if let session { confirmDeleteCurrent(session) }
        }
        @objc private func menuComment() { session?.openCommentEditor() }
        @objc private func menuNag(_ sender: NSMenuItem) {
            session?.applyNag(UInt8(sender.tag))
        }
        @objc private func menuClearNags() { session?.clearNags() }
        @objc private func menuCopyPgn() {
            guard let session else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.game.toPgn(), forType: .string)
        }
        @objc private func menuCopyFen() {
            guard let session else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.fen, forType: .string)
        }
        @objc private func menuExport() {
            if let session { exportGamePgn(session) }
        }
    }

    // --- token stream -> attributed string (rendering contract) ---

    private static let indentStep: CGFloat = 16

    static func buildAttributed(_ tokens: [NotationToken]) -> (NSAttributedString, [UInt32: NSRange]) {
        let text = NSMutableAttributedString()
        var ranges: [UInt32: NSRange] = [:]
        var paragraph = paragraphStyle(indent: 0)
        var needSpace = false

        func append(_ string: String, _ attributes: [NSAttributedString.Key: Any]) -> NSRange {
            var attrs = attributes
            attrs[.paragraphStyle] = paragraph
            let range = NSRange(location: text.length, length: (string as NSString).length)
            text.append(NSAttributedString(string: string, attributes: attrs))
            return range
        }

        for token in tokens {
            switch token.kind {
            case .paragraphBreak:
                _ = append("\n", [:])
                paragraph = paragraphStyle(indent: CGFloat(token.depth) * indentStep)
                needSpace = false
                continue
            case .closeParen:
                _ = append(")", variationAttributes(depth: token.depth))
                needSpace = true
                continue
            default:
                break
            }
            if needSpace { _ = append(" ", [:]) }
            switch token.kind {
            case .openParen:
                _ = append("(", variationAttributes(depth: token.depth))
                needSpace = false
            case .moveNumber:
                var attrs = moveAttributes(depth: token.depth)
                attrs[.dcsNode] = tagged(token)
                _ = append(token.text, attrs)
                needSpace = true
            case .move:
                var attrs = moveAttributes(depth: token.depth)
                attrs[.dcsNode] = tagged(token)
                let range = append(token.text, attrs)
                if let node = token.nodeId { ranges[node] = range }
                needSpace = true
            case .nag:
                var attrs = moveAttributes(depth: token.depth)
                attrs[.dcsNode] = tagged(token)
                _ = append(token.text, attrs)
                needSpace = true
            case .comment:
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.systemGreen,
                ]
                attrs[.dcsNode] = tagged(token)
                _ = append(token.text, attrs)
                needSpace = true
            case .paragraphBreak, .closeParen:
                break
            }
        }
        return (text, ranges)
    }

    private static func tagged(_ token: NotationToken) -> Any {
        NSNumber(value: token.nodeId ?? 0)
    }

    private static func moveAttributes(depth: UInt32) -> [NSAttributedString.Key: Any] {
        if depth == 0 {
            return [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
        }
        return variationAttributes(depth: depth)
    }

    private static func variationAttributes(depth: UInt32) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: depth <= 1 ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
        ]
    }

    private static func paragraphStyle(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacing = 3
        style.lineSpacing = 1.5
        return style
    }
}

/// Read-only text view that maps clicks to node ids via .dcsNode.
final class NotationTextView: NSTextView {
    var onNodeClick: ((UInt32) -> Void)?
    var onContextMenu: ((UInt32?) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let onContextMenu else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        var node: UInt32?
        if let storage = textStorage {
            for probe in [index, index - 1] where probe >= 0 && probe < storage.length {
                if let n = storage.attribute(.dcsNode, at: probe, effectiveRange: nil) as? NSNumber,
                   n.uint32Value != 0 {
                    node = n.uint32Value
                    break
                }
            }
        }
        return onContextMenu(node)
    }

    override func mouseDown(with event: NSEvent) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        // an insertion index can sit just past the clicked glyph; probe both sides
        for probe in [index, index - 1] where probe >= 0 && probe < storage.length {
            if let node = storage.attribute(.dcsNode, at: probe, effectiveRange: nil) as? NSNumber {
                onNodeClick?(node.uint32Value)
                return
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
