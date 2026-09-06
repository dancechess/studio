import AppKit

/// Print / PDF for one game: the notation panel's own attributed text,
/// paginated by AppKit. A handout is the same document as the screen.
@MainActor
enum GamePrinter {
    private static func printView(for session: GameSession, info: NSPrintInfo) -> NSTextView {
        // the content column is the paper minus our margins — the printer's
        // imageable bounds are wider than that and clipped the right edge
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainerInset = .zero
        view.textStorage?.setAttributedString(NotationView.document(for: session))
        if let lm = view.layoutManager, let tc = view.textContainer {
            lm.ensureLayout(for: tc)
            view.frame.size.height = lm.usedRect(for: tc).height + 8
        }
        return view
    }

    private static func baseInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 40; info.bottomMargin = 40
        info.leftMargin = 44; info.rightMargin = 44
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.verticalPagination = .automatic
        return info
    }

    static func print(_ session: GameSession) {
        let info = baseInfo()
        let op = NSPrintOperation(view: printView(for: session, info: info), printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }

    static func exportPdf(_ session: GameSession) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let white = session.game.header(key: "White") ?? "game"
        let black = session.game.header(key: "Black") ?? ""
        panel.nameFieldStringValue = black.isEmpty ? "\(white).pdf" : "\(white) - \(black).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportPdf(session, to: url)
    }

    static func exportPdf(_ session: GameSession, to url: URL) {
        let info = baseInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let op = NSPrintOperation(view: printView(for: session, info: info), printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if !op.run() {
            session.errorText = "PDF export failed"
        }
    }
}
