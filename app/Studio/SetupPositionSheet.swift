import AppKit
import SwiftUI
#if canImport(DanceChessCore)
import DanceChessCore
#endif

/// DCS_SETUP_DEBUG=1: appends gesture/event traces to /tmp/dcs-setup-debug.log.
@MainActor
func setupDebugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["DCS_SETUP_DEBUG"] != nil else { return }
    let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(message)\n"
    let path = "/tmp/dcs-setup-debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

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
    @State private var debugMonitor: Any?

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
        .onAppear {
            setupDebugLog("sheet appeared")
            if ProcessInfo.processInfo.environment["DCS_SETUP_DEBUG"] != nil {
                debugMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
                ) { event in
                    setupDebugLog("nsevent type=\(event.type.rawValue) window=\(event.windowNumber) loc=\(event.locationInWindow)")
                    return event
                }
            }
        }
        .onDisappear {
            if let debugMonitor { NSEvent.removeMonitor(debugMonitor) }
            debugMonitor = nil
        }
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
        .coordinateSpace(name: "setupBoard")
        .overlay(
            Rectangle()
                .strokeBorder(Color.secondary.opacity(0.4))
                .allowsHitTesting(false)
        )
    }

    /// Drag gesture attached per square (a container-level gesture gets
    /// starved by the squares' tap gestures inside a sheet); locations are
    /// resolved in the shared "setupBoard" space.
    private func dragGesture(from index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("setupBoard"))
            .onChanged { value in
                setupDebugLog("drag changed square=\(index) loc=\(value.location) piece=\(dragPiece.map(String.init) ?? "nil") onSquare=\(squares[index].map(String.init) ?? "nil")")
                if dragPiece == nil {
                    guard let piece = squares[index] else { return }
                    dragPiece = piece
                    squares[index] = nil
                    errorText = nil
                }
                dragLocation = value.location
            }
            .onEnded { value in
                setupDebugLog("drag ended square=\(index) loc=\(value.location) to=\(squareAt(value.location).map(String.init) ?? "off-board") piece=\(dragPiece.map(String.init) ?? "nil")")
                defer {
                    dragPiece = nil
                    dragLocation = nil
                }
                guard let piece = dragPiece else { return }
                if let to = squareAt(value.location) {
                    squares[to] = piece
                } // else: dropped off the board — the piece stays removed
            }
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
            setupDebugLog("tap square=\(index)")
            errorText = nil
            // painting the same piece again erases it (quick toggling)
            squares[index] = (squares[index] == tool) ? nil : tool
        }
        .gesture(dragGesture(from: index))
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
