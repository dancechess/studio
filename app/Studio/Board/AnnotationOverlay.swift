import SwiftUI
import AppKit

/// Draws the current position's [%csl] square highlights and [%cal] arrows
/// above the pieces (lichess-style). Coordinates respect board flipping.
struct AnnotationOverlay: View {
    let session: GameSession
    let cell: CGFloat

    private static let colors: [Character: Color] = [
        "G": Color(red: 0.15, green: 0.75, blue: 0.26),
        "R": Color(red: 0.86, green: 0.20, blue: 0.15),
        "Y": Color(red: 0.95, green: 0.75, blue: 0.10),
        "B": Color(red: 0.15, green: 0.45, blue: 0.85),
    ]

    var body: some View {
        let annotations = session.annotations
        let flipped = session.flipped
        Canvas { context, _ in
            for (square, colorCode) in annotations.squares {
                let rect = squareRect(square, flipped: flipped)
                context.fill(Path(rect.insetBy(dx: cell * 0.03, dy: cell * 0.03)),
                             with: .color(color(colorCode).opacity(0.45)))
            }
            for arrow in annotations.arrows {
                let path = arrowPath(from: center(arrow.from, flipped: flipped),
                                     to: center(arrow.to, flipped: flipped))
                context.fill(path, with: .color(color(arrow.color).opacity(0.75)))
            }
        }
        .frame(width: cell * 8, height: cell * 8)
    }

    private func color(_ code: Character) -> Color {
        Self.colors[code] ?? Self.colors["G"]!
    }

    private func displayPoint(_ square: Int, flipped: Bool) -> (col: Int, row: Int) {
        var file = square % 8
        var rank = square / 8
        if flipped {
            file = 7 - file
            rank = 7 - rank
        }
        return (file, 7 - rank) // row 0 = top of the view
    }

    private func squareRect(_ square: Int, flipped: Bool) -> CGRect {
        let p = displayPoint(square, flipped: flipped)
        return CGRect(x: CGFloat(p.col) * cell, y: CGFloat(p.row) * cell,
                      width: cell, height: cell)
    }

    private func center(_ square: Int, flipped: Bool) -> CGPoint {
        let rect = squareRect(square, flipped: flipped)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// A stubby arrow: shaft + triangular head, slightly inset at the tail.
    private func arrowPath(from: CGPoint, to: CGPoint) -> Path {
        let vector = CGVector(dx: to.x - from.x, dy: to.y - from.y)
        let length = max(sqrt(vector.dx * vector.dx + vector.dy * vector.dy), 1)
        let unit = CGVector(dx: vector.dx / length, dy: vector.dy / length)
        let normal = CGVector(dx: -unit.dy, dy: unit.dx)
        let shaftWidth = cell * 0.22
        let headWidth = cell * 0.55
        let headLength = cell * 0.42
        let tailInset = cell * 0.28
        let start = CGPoint(x: from.x + unit.dx * tailInset,
                            y: from.y + unit.dy * tailInset)
        let headBase = CGPoint(x: to.x - unit.dx * headLength,
                               y: to.y - unit.dy * headLength)
        var path = Path()
        func offset(_ p: CGPoint, _ d: CGFloat) -> CGPoint {
            CGPoint(x: p.x + normal.dx * d, y: p.y + normal.dy * d)
        }
        path.move(to: offset(start, shaftWidth / 2))
        path.addLine(to: offset(headBase, shaftWidth / 2))
        path.addLine(to: offset(headBase, headWidth / 2))
        path.addLine(to: to)
        path.addLine(to: offset(headBase, -headWidth / 2))
        path.addLine(to: offset(headBase, -shaftWidth / 2))
        path.addLine(to: offset(start, -shaftWidth / 2))
        path.closeSubpath()
        return path
    }
}

/// Transparent AppKit layer that catches ONLY right-mouse interactions
/// (left clicks/drags fall through to the SwiftUI board underneath).
/// Reports the press point, modifiers, and — for drags — the release point,
/// all in top-left SwiftUI coordinates.
struct RightClickCatcher: NSViewRepresentable {
    let onRightAction: (_ point: CGPoint, _ modifiers: NSEvent.ModifierFlags,
                        _ dragTo: CGPoint?) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightAction = onRightAction
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightAction = onRightAction
    }

    final class CatcherView: NSView {
        var onRightAction: ((CGPoint, NSEvent.ModifierFlags, CGPoint?) -> Void)?
        private var pressPoint: CGPoint?
        private var pressModifiers: NSEvent.ModifierFlags = []

        // claim only right-button events; everything else passes through
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        private func flip(_ p: NSPoint) -> CGPoint {
            CGPoint(x: p.x, y: bounds.height - p.y) // AppKit → SwiftUI coords
        }

        override func rightMouseDown(with event: NSEvent) {
            pressPoint = flip(convert(event.locationInWindow, from: nil))
            pressModifiers = event.modifierFlags
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let start = pressPoint else { return }
            pressPoint = nil
            let end = flip(convert(event.locationInWindow, from: nil))
            let distance = hypot(end.x - start.x, end.y - start.y)
            onRightAction?(start, pressModifiers, distance > 8 ? end : nil)
        }
    }
}
