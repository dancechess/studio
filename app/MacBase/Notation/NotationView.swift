import AppKit
import SwiftUI
#if canImport(MacBaseCore)
import MacBaseCore
#endif

// Design: docs/NOTATION-VIEW.md. The token stream comes from Rust
// (Game.notationTokens()); this file only renders and hit-tests.

extension NSAttributedString.Key {
    /// UInt32 node id carried by every move/number/nag/comment run.
    static let macbaseNode = NSAttributedString.Key("macbaseNodeID")
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

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NotationTextView else { return }
        let coordinator = context.coordinator
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
    final class Coordinator {
        var version = -1
        var nodeRanges: [UInt32: NSRange] = [:]
        var highlighted: NSRange?

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
                attrs[.macbaseNode] = tagged(token)
                _ = append(token.text, attrs)
                needSpace = true
            case .move:
                var attrs = moveAttributes(depth: token.depth)
                attrs[.macbaseNode] = tagged(token)
                let range = append(token.text, attrs)
                if let node = token.nodeId { ranges[node] = range }
                needSpace = true
            case .nag:
                var attrs = moveAttributes(depth: token.depth)
                attrs[.macbaseNode] = tagged(token)
                _ = append(token.text, attrs)
                needSpace = true
            case .comment:
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.systemGreen,
                ]
                attrs[.macbaseNode] = tagged(token)
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

/// Read-only text view that maps clicks to node ids via .macbaseNode.
final class NotationTextView: NSTextView {
    var onNodeClick: ((UInt32) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        // an insertion index can sit just past the clicked glyph; probe both sides
        for probe in [index, index - 1] where probe >= 0 && probe < storage.length {
            if let node = storage.attribute(.macbaseNode, at: probe, effectiveRange: nil) as? NSNumber {
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
