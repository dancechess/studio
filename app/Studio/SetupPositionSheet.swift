import SwiftUI
#if canImport(DanceChessCore)
import DanceChessCore
#endif

/// Position composer: click-to-paint pieces onto a board, pick side to
/// move and castling rights, and start a new (scratch) game from the
/// resulting FEN. Validation is the Rust move generator — if it can't
/// produce legal moves for the FEN, the position is rejected.
struct SetupPositionSheet: View {
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// a1 = 0 … h8 = 63, FEN letters (uppercase = white); nil = empty.
    @State private var squares: [Character?] = Self.startPosition()
    /// Selected palette tool; nil = eraser.
    @State private var tool: Character? = "P"
    @State private var whiteToMove = true
    @State private var castleWK = true
    @State private var castleWQ = true
    @State private var castleBK = true
    @State private var castleBQ = true
    @State private var errorText: String?
    // drag-to-move state (dragging off the board deletes the piece)
    @State private var dragPiece: Character?
    @State private var dragLocation: CGPoint?

    private let lightColor = Color(red: 0.94, green: 0.85, blue: 0.71)
    private let darkColor = Color(red: 0.71, green: 0.53, blue: 0.39)
    private let cell: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Position")
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                board
                VStack(alignment: .leading, spacing: 10) {
                    palette(for: "PNBRQK")
                    palette(for: "pnbrqk")
                    eraser
                    Divider()
                    Picker("To move", selection: $whiteToMove) {
                        Text("White").tag(true)
                        Text("Black").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    Text("Castling")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("White O-O", isOn: $castleWK)
                    Toggle("White O-O-O", isOn: $castleWQ)
                    Toggle("Black O-O", isOn: $castleBK)
                    Toggle("Black O-O-O", isOn: $castleBQ)
                }
                .toggleStyle(.checkbox)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Empty Board") { squares = Array(repeating: nil, count: 64) }
                Button("Start Position") { squares = Self.startPosition() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Game") { create() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620)
    }

    private var board: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach((0..<8).reversed(), id: \.self) { rank in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { file in
                            square(rank * 8 + file)
                        }
                    }
                }
            }
            if let dragPiece, let dragLocation {
                PieceView(piece: BoardPiece(symbol: dragPiece), cell: cell)
                    .position(dragLocation)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: cell * 8, height: cell * 8)
        .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.4)))
        // drag an already-placed piece to another square; off the board = delete
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .local)
                .onChanged { value in
                    if dragPiece == nil {
                        guard let from = squareAt(value.startLocation),
                              let piece = squares[from] else { return }
                        dragPiece = piece
                        squares[from] = nil
                        errorText = nil
                    }
                    dragLocation = value.location
                }
                .onEnded { value in
                    defer {
                        dragPiece = nil
                        dragLocation = nil
                    }
                    guard let piece = dragPiece else { return }
                    if let to = squareAt(value.location) {
                        squares[to] = piece
                    } // else: dropped off the board — the piece stays removed
                }
        )
    }

    private func squareAt(_ point: CGPoint) -> Int? {
        let file = Int(floor(point.x / cell))
        let rank = 7 - Int(floor(point.y / cell))
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        return rank * 8 + file
    }

    private func square(_ index: Int) -> some View {
        let isLight = (index / 8 + index % 8) % 2 == 1
        return ZStack {
            isLight ? lightColor : darkColor
            if let symbol = squares[index] {
                PieceView(piece: BoardPiece(symbol: symbol), cell: cell)
            }
        }
        .frame(width: cell, height: cell)
        .contentShape(Rectangle())
        .onTapGesture {
            errorText = nil
            // painting the same piece again erases it (quick toggling)
            squares[index] = (squares[index] == tool) ? nil : tool
        }
    }

    private func palette(for symbols: String) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(symbols), id: \.self) { symbol in
                Button {
                    tool = symbol
                } label: {
                    PieceView(piece: BoardPiece(symbol: symbol), cell: 30)
                        .padding(3)
                        .background(tool == symbol ? Color.accentColor.opacity(0.3) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var eraser: some View {
        Button {
            tool = nil
        } label: {
            Label("Eraser", systemImage: "xmark.circle")
                .padding(3)
                .background(tool == nil ? Color.accentColor.opacity(0.3) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func create() {
        let fen = buildFen()
        do {
            _ = try legalMovesDetailed(fen: fen) // Rust validates the position
            onCreate(fen)
            dismiss()
        } catch {
            errorText = "Invalid position: \(error.localizedDescription)"
        }
    }

    private func buildFen() -> String {
        var rows: [String] = []
        for rank in (0..<8).reversed() {
            var row = ""
            var empties = 0
            for file in 0..<8 {
                if let piece = squares[rank * 8 + file] {
                    if empties > 0 {
                        row += String(empties)
                        empties = 0
                    }
                    row.append(piece)
                } else {
                    empties += 1
                }
            }
            if empties > 0 { row += String(empties) }
            rows.append(row)
        }
        // castling rights only where king and rook still sit at home
        var castling = ""
        if castleWK, squares[4] == "K", squares[7] == "R" { castling += "K" }
        if castleWQ, squares[4] == "K", squares[0] == "R" { castling += "Q" }
        if castleBK, squares[60] == "k", squares[63] == "r" { castling += "k" }
        if castleBQ, squares[60] == "k", squares[56] == "r" { castling += "q" }
        if castling.isEmpty { castling = "-" }
        return "\(rows.joined(separator: "/")) \(whiteToMove ? "w" : "b") \(castling) - 0 1"
    }

    private static func startPosition() -> [Character?] {
        var board: [Character?] = Array(repeating: nil, count: 64)
        let back = "RNBQKBNR"
        for (file, piece) in back.enumerated() {
            board[file] = piece
            board[8 + file] = "P"
            board[48 + file] = "p"
            board[56 + file] = Character(piece.lowercased())
        }
        return board
    }
}
