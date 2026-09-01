import SwiftUI
#if canImport(DanceChessCore)
import DanceChessCore
#endif

/// The chess board: tap-tap or drag a piece to move. Non-mainline moves
/// automatically open a variation (handled by the Rust tree); promotions
/// pop a piece picker over the promotion square.
struct BoardView: View {
    let session: GameSession
    @State private var selected: Int?
    @State private var dragFrom: Int?
    @State private var dragLocation: CGPoint?

    private let lightColor = Color(red: 0.94, green: 0.85, blue: 0.71)
    private let darkColor = Color(red: 0.71, green: 0.53, blue: 0.39)

    var body: some View {
        GeometryReader { geo in
            let cell = min(geo.size.width, geo.size.height) / 8
            let targets = selected.map { session.targets(from: $0) } ?? []
            let ranks = session.flipped ? Array(0..<8) : Array((0..<8).reversed())
            let files = session.flipped ? Array((0..<8).reversed()) : Array(0..<8)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(ranks, id: \.self) { rank in
                        HStack(spacing: 0) {
                            ForEach(files, id: \.self) { file in
                                square(rank * 8 + file, cell: cell, targets: targets)
                            }
                        }
                    }
                }
                if let from = dragFrom, let location = dragLocation,
                   let piece = session.squares[from] {
                    PieceView(piece: piece, cell: cell)
                        .position(location)
                        .allowsHitTesting(false)
                }
                if let request = session.pendingPromotion {
                    promotionPicker(request, cell: cell)
                }
            }
            .frame(width: cell * 8, height: cell * 8)
            .gesture(dragGesture(cell: cell))
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
                PieceView(piece: piece, cell: cell)
                    .opacity(index == dragFrom ? 0.3 : 1)
            }
            coordinateLabels(index, cell: cell, isLight: isLight)
        }
        .frame(width: cell, height: cell)
        .contentShape(Rectangle())
        .onTapGesture { tap(index) }
    }

    /// chess.com-style coordinates: file letters in the displayed bottom
    /// row (bottom-right corner), rank numbers in the displayed left column
    /// (top-left corner), tinted with the opposite square color.
    @ViewBuilder
    private func coordinateLabels(_ index: Int, cell: CGFloat, isLight: Bool) -> some View {
        let rank = index / 8
        let file = index % 8
        let labelColor = isLight ? darkColor : lightColor
        if rank == (session.flipped ? 7 : 0) {
            Text(String(UnicodeScalar(97 + file)!))
                .font(.system(size: cell * 0.18, weight: .semibold))
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomTrailing)
                .padding(2)
        }
        if file == (session.flipped ? 7 : 0) {
            Text("\(rank + 1)")
                .font(.system(size: cell * 0.18, weight: .semibold))
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)
                .padding(2)
        }
    }

    private func tap(_ index: Int) {
        guard session.pendingPromotion == nil else { return }
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

    // --- drag to move ---

    private func dragGesture(cell: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                guard session.pendingPromotion == nil else { return }
                if dragFrom == nil {
                    guard let start = squareAt(value.startLocation, cell: cell),
                          let piece = session.squares[start],
                          piece.isWhite == session.whiteToMove
                    else { return }
                    dragFrom = start
                    selected = start
                }
                dragLocation = value.location
            }
            .onEnded { value in
                defer {
                    dragFrom = nil
                    dragLocation = nil
                }
                guard let from = dragFrom,
                      let to = squareAt(value.location, cell: cell),
                      session.targets(from: from).contains(to)
                else { return }
                session.play(from: from, to: to)
                selected = nil
            }
    }

    private func squareAt(_ point: CGPoint, cell: CGFloat) -> Int? {
        var file = Int(floor(point.x / cell))
        var rank = 7 - Int(floor(point.y / cell))
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        if session.flipped {
            file = 7 - file
            rank = 7 - rank
        }
        return rank * 8 + file
    }

    // --- promotion piece picker ---

    @ViewBuilder
    private func promotionPicker(_ request: PromotionRequest, cell: CGFloat) -> some View {
        // backdrop swallows board clicks; clicking it cancels
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .onTapGesture { session.cancelPromotion() }
        let letters = ["q", "r", "b", "n"]
        let file = request.to % 8
        let rank = request.to / 8
        let displayFile = session.flipped ? 7 - file : file
        let displayTop = (rank == 7) != session.flipped
        let panelX = min(max(CGFloat(displayFile) * cell + cell / 2, cell * 2.1), cell * 5.9)
        let panelY = displayTop ? cell * 0.55 : cell * 7.45
        HStack(spacing: 2) {
            ForEach(letters, id: \.self) { letter in
                let symbol = Character(request.isWhite ? letter.uppercased() : letter)
                Button {
                    session.promote(to: letter)
                } label: {
                    PieceView(piece: BoardPiece(symbol: symbol), cell: cell * 0.9)
                        .frame(width: cell * 0.95, height: cell * 0.95)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 6)
        .position(x: panelX, y: panelY)
    }
}
