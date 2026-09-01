import Foundation
import Observation
#if canImport(MacBaseCore)
import MacBaseCore
#endif

struct BoardPiece: Equatable {
    let symbol: Character // FEN letter: uppercase = white
    var isWhite: Bool { symbol.isUppercase }

    var glyph: String {
        switch symbol {
        case "K": "♔"; case "Q": "♕"; case "R": "♖"
        case "B": "♗"; case "N": "♘"; case "P": "♙"
        case "k": "♚"; case "q": "♛"; case "r": "♜"
        case "b": "♝"; case "n": "♞"; case "p": "♟"
        default: "?"
        }
    }
}

/// Single source of truth for one open game: the Rust `Game` plus the
/// current node. Board, notation and (later) engine panels all observe it.
@Observable
@MainActor
final class GameSession {
    private(set) var game = Game()
    private(set) var currentNode: UInt32 = 0
    private(set) var fen: String = ""
    /// 64 squares, index 0 = a1 ... 63 = h8.
    private(set) var squares: [BoardPiece?] = Array(repeating: nil, count: 64)
    private(set) var whiteToMove = true
    private(set) var legalMoves: [LegalMove] = []
    private(set) var tokens: [NotationToken] = []
    /// Bumped on every tree edit; the notation view rebuilds only then.
    private(set) var tokensVersion = 0
    private(set) var lastMove: (from: Int, to: Int)?
    var errorText: String?

    var gameTitle: String {
        let white = game.header(key: "White") ?? ""
        let black = game.header(key: "Black") ?? ""
        if white.isEmpty && black.isEmpty { return "New Game" }
        return "\(white) – \(black)"
    }

    init() {
        rebuildTokens()
        refresh()
    }

    func loadPgn(_ pgn: String) {
        do {
            game = try Game.fromPgn(pgn: pgn)
            currentNode = 0
            rebuildTokens()
            refresh()
        } catch {
            errorText = "\(error)"
        }
    }

    // --- navigation ---

    func select(_ node: UInt32) {
        currentNode = node
        refresh()
    }

    func back() {
        if let parent = game.node(id: currentNode).parent { select(parent) }
    }

    func forward() {
        if let child = game.node(id: currentNode).children.first { select(child) }
    }

    func toStart() { select(0) }

    func toEnd() {
        var node = currentNode
        while let child = game.node(id: node).children.first { node = child }
        select(node)
    }

    // --- board interaction ---

    func squareIndex(_ name: String) -> Int {
        let chars = Array(name.unicodeScalars)
        guard chars.count == 2 else { return 0 }
        return Int(chars[0].value - 97) + Int(chars[1].value - 49) * 8
    }

    func targets(from: Int) -> Set<Int> {
        Set(legalMoves.filter { squareIndex($0.from) == from }.map { squareIndex($0.to) })
    }

    /// Plays from/to; auto-queens promotions for now (picker comes later).
    func play(from: Int, to: Int) {
        let matches = legalMoves.filter { squareIndex($0.from) == from && squareIndex($0.to) == to }
        guard let move = matches.first(where: { $0.promotion == "q" }) ?? matches.first else { return }
        do {
            let node = try game.addMove(id: currentNode, san: move.san)
            rebuildTokens()
            select(node)
        } catch {
            errorText = "\(error)"
        }
    }

    // --- internals ---

    private func rebuildTokens() {
        tokens = game.notationTokens()
        tokensVersion += 1
    }

    private func refresh() {
        do {
            fen = try game.fenAt(id: currentNode)
            legalMoves = try game.legalMovesDetailedAt(id: currentNode)
            if let coords = try game.moveCoords(id: currentNode) {
                lastMove = (squareIndex(coords.from), squareIndex(coords.to))
            } else {
                lastMove = nil
            }
            applyFen()
            errorText = nil
        } catch {
            errorText = "\(error)"
        }
    }

    private func applyFen() {
        var board: [BoardPiece?] = Array(repeating: nil, count: 64)
        let fields = fen.split(separator: " ")
        guard let boardField = fields.first else { return }
        var rank = 7, file = 0
        for ch in boardField {
            if ch == "/" {
                rank -= 1
                file = 0
            } else if let skip = ch.wholeNumberValue, ch.isNumber {
                file += skip
            } else {
                if rank >= 0 && file < 8 {
                    board[rank * 8 + file] = BoardPiece(symbol: ch)
                }
                file += 1
            }
        }
        squares = board
        whiteToMove = fields.count > 1 && fields[1] == "w"
    }
}
