import AppKit

/// A static board picture of a FEN — the diagram in the notation panel and
/// on paper. Same square colours as the live board, same Merida pieces.
@MainActor
enum BoardImage {
    static let light = NSColor(red: 0.94, green: 0.85, blue: 0.71, alpha: 1)
    static let dark = NSColor(red: 0.71, green: 0.53, blue: 0.39, alpha: 1)

    static func render(fen: String, size: CGFloat, flipped: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let cell = size / 8
        let placement = fen.split(separator: " ").first.map(String.init) ?? ""
        // squares (drawn from a1 at the bottom-left unless flipped)
        for rank in 0..<8 {
            for file in 0..<8 {
                let isLight = (rank + file) % 2 == 1
                (isLight ? light : dark).setFill()
                let x = CGFloat(flipped ? 7 - file : file) * cell
                let y = CGFloat(flipped ? 7 - rank : rank) * cell
                NSRect(x: x, y: y, width: cell, height: cell).fill()
            }
        }
        // pieces: FEN ranks run 8 → 1
        var rank = 7
        var file = 0
        for ch in placement {
            if ch == "/" { rank -= 1; file = 0; continue }
            if let n = ch.wholeNumberValue { file += n; continue }
            let x = CGFloat(flipped ? 7 - file : file) * cell
            let y = CGFloat(flipped ? 7 - rank : rank) * cell
            let rect = NSRect(x: x, y: y, width: cell, height: cell)
            if let piece = PieceAssets.image(for: ch) {
                piece.draw(in: rect.insetBy(dx: cell * 0.04, dy: cell * 0.04),
                           from: .zero, operation: .sourceOver, fraction: 1)
            }
            file += 1
        }
        NSColor(white: 0, alpha: 0.35).setStroke()
        NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1)).stroke()
        image.unlockFocus()
        return image
    }
}
