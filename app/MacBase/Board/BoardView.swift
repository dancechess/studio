import SwiftUI
#if canImport(MacBaseCore)
import MacBaseCore
#endif

/// The chess board: tap a piece, tap a destination. Non-mainline moves
/// automatically open a variation (handled by the Rust tree).
struct BoardView: View {
    let session: GameSession
    @State private var selected: Int?

    private let lightColor = Color(red: 0.94, green: 0.85, blue: 0.71)
    private let darkColor = Color(red: 0.71, green: 0.53, blue: 0.39)

    var body: some View {
        GeometryReader { geo in
            let cell = min(geo.size.width, geo.size.height) / 8
            let targets = selected.map { session.targets(from: $0) } ?? []
            VStack(spacing: 0) {
                ForEach((0..<8).reversed(), id: \.self) { rank in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { file in
                            square(rank * 8 + file, cell: cell, targets: targets)
                        }
                    }
                }
            }
            .frame(width: cell * 8, height: cell * 8)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func square(_ index: Int, cell: CGFloat, targets: Set<Int>) -> some View {
        let isLight = (index / 8 + index % 8) % 2 == 1
        let piece = session.squares[index]
        ZStack {
            (isLight ? lightColor : darkColor)
            if let last = session.lastMove, index == last.from || index == last.to {
                Color.yellow.opacity(0.35)
            }
            if index == selected {
                Rectangle().strokeBorder(Color.green.opacity(0.8), lineWidth: 3)
            }
            if targets.contains(index) {
                if piece != nil {
                    Circle()
                        .strokeBorder(Color.green.opacity(0.65), lineWidth: cell * 0.08)
                        .padding(cell * 0.04)
                } else {
                    Circle()
                        .fill(Color.green.opacity(0.5))
                        .frame(width: cell * 0.3, height: cell * 0.3)
                }
            }
            if let piece {
                Text(piece.glyph)
                    .font(.system(size: cell * 0.78))
                    .foregroundStyle(.black)
                    .shadow(color: piece.isWhite ? .white.opacity(0.6) : .clear, radius: 1)
            }
        }
        .frame(width: cell, height: cell)
        .contentShape(Rectangle())
        .onTapGesture { tap(index) }
    }

    private func tap(_ index: Int) {
        if let from = selected, session.targets(from: from).contains(index) {
            session.play(from: from, to: index)
            selected = nil
            return
        }
        if let piece = session.squares[index], piece.isWhite == session.whiteToMove {
            selected = (selected == index) ? nil : index
        } else {
            selected = nil
        }
    }
}
