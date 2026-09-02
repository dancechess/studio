import Foundation
import Observation
#if canImport(DanceChessCore)
import DanceChessCore
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

/// One entry in the variation-choice popup shown when → hits a branch point.
struct VariationChoice: Identifiable, Equatable {
    let id: UInt32 // node id of the candidate first move
    let label: String // e.g. "2.Nf3" / "2...c5"
}

/// A pending promotion: from/to are fixed, the piece is still to be chosen.
struct PromotionRequest: Equatable {
    let from: Int
    let to: Int
    let isWhite: Bool
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
    /// Non-nil while the variation-choice popup is up (→ at a branch point).
    private(set) var variationChoices: [VariationChoice]?
    var variationIndex = 0
    /// Non-nil while the promotion piece picker is up.
    private(set) var pendingPromotion: PromotionRequest?
    var errorText: String?
    /// Board orientation (view preference; not part of the game data).
    private(set) var flipped = false

    func toggleFlip() { flipped.toggle() }

    // --- undo/redo: whole-game PGN snapshots (games are small, and a
    // snapshot restore also brings the cursor back) ---
    private var undoStack: [(pgn: String, node: UInt32)] = []
    private var redoStack: [(pgn: String, node: UInt32)] = []

    /// Call before every tree mutation.
    private func snapshot() {
        undoStack.append((game.toPgn(), currentNode))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let state = undoStack.popLast() else { return }
        redoStack.append((game.toPgn(), currentNode))
        restore(state)
    }

    func redo() {
        guard let state = redoStack.popLast() else { return }
        undoStack.append((game.toPgn(), currentNode))
        restore(state)
    }

    private func restore(_ state: (pgn: String, node: UInt32)) {
        do {
            game = try Game.fromPgn(pgn: state.pgn)
            rebuildTokens()
            select(state.node)
        } catch {
            errorText = "\(error)"
        }
    }
    /// `games.id` this session was loaded from, or -1 for a scratch game.
    private(set) var sourceGameId: Int64 = -1
    /// Canonical PGN at load/save time; `isModified` compares against it, so
    /// there is no per-edit flag to keep in sync (games are small — cheap).
    private var baselinePgn = ""

    var isModified: Bool { game.toPgn() != baselinePgn }

    private static let standardStart = startFen()

    /// The position to analyze: nil at the root of a standard game (no move
    /// highlighted, and analyzing the start position is noise) — but a
    /// custom-FEN game's root IS the position of interest (puzzle, endgame),
    /// so it analyzes like any selected move.
    var highlightedFen: String? {
        if currentNode != 0 { return fen }
        return fen == Self.standardStart ? nil : fen
    }

    /// Called when the list this game came from is replaced: the id no
    /// longer refers to it, so edits become scratch instead of risking a
    /// write into whatever game now holds that id.
    func detachFromDatabase() { sourceGameId = -1 }

    /// A newly entered game was appended to the list under this id.
    func attachToDatabase(id: Int64) {
        sourceGameId = id
        markSaved()
    }

    /// Back to an empty scratch board — used when a different (empty) list
    /// is opened, so a stale game never lingers over the new list.
    func resetToBlank() {
        game = Game()
        sourceGameId = -1
        undoStack.removeAll()
        redoStack.removeAll()
        baselinePgn = game.toPgn()
        currentNode = 0
        variationChoices = nil
        pendingPromotion = nil
        rebuildTokens()
        refresh()
    }

    /// Any moves on the board at all (scratch games with none aren't worth
    /// a save prompt).
    var hasMoves: Bool { !game.node(id: 0).children.isEmpty }

    func setHeaders(_ pairs: [(String, String)]) {
        snapshot()
        for (key, value) in pairs {
            game.setHeader(key: key, value: value)
        }
        rebuildTokens()
    }

    func markSaved() { baselinePgn = game.toPgn() }

    var gameTitle: String {
        let white = game.header(key: "White") ?? ""
        let black = game.header(key: "Black") ?? ""
        if white.isEmpty && black.isEmpty { return "New Game" }
        return "\(white) – \(black)"
    }

    init() {
        baselinePgn = game.toPgn()
        rebuildTokens()
        refresh()
        SessionRegistry.shared.register(self)
    }

    func loadPgn(_ pgn: String, sourceId: Int64 = -1) {
        do {
            game = try Game.fromPgn(pgn: pgn)
            sourceGameId = sourceId
            undoStack.removeAll()
            redoStack.removeAll()
            // baseline is the *normalized* form, so a load-then-no-edit
            // session never reads as modified
            baselinePgn = game.toPgn()
            currentNode = 0
            rebuildTokens()
            refresh()
        } catch {
            errorText = "\(error)"
        }
    }

    // --- navigation ---

    func select(_ node: UInt32) {
        variationChoices = nil
        pendingPromotion = nil
        currentNode = node
        refresh()
    }

    func back() {
        if let parent = game.node(id: currentNode).parent { select(parent) }
    }

    /// Advances along the tree; at a branch point opens the variation popup
    /// instead of silently taking the mainline (ChessBase behavior).
    func forward() {
        let children = game.node(id: currentNode).children
        if children.count > 1 {
            variationChoices = children.map { VariationChoice(id: $0, label: moveLabel($0)) }
            variationIndex = 0
        } else if let child = children.first {
            select(child)
        }
    }

    // --- variation-choice popup ---

    func variationStep(_ delta: Int) {
        guard let choices = variationChoices, !choices.isEmpty else { return }
        variationIndex = (variationIndex + delta + choices.count) % choices.count
    }

    func variationConfirm() {
        guard let choices = variationChoices, !choices.isEmpty else { return }
        select(choices[min(max(variationIndex, 0), choices.count - 1)].id)
    }

    func variationCancel() { variationChoices = nil }

    func chooseVariation(_ node: UInt32) { select(node) }

    /// ↑/↓: jump between the first moves of sibling variations.
    func previousLine() { stepLine(-1) }
    func nextLine() { stepLine(1) }

    private func stepLine(_ delta: Int) {
        guard let parent = game.node(id: currentNode).parent else { return }
        let siblings = game.node(id: parent).children
        guard let i = siblings.firstIndex(of: currentNode) else { return }
        let j = i + delta
        guard siblings.indices.contains(j) else { return }
        select(siblings[j])
    }

    private func moveLabel(_ id: UInt32) -> String {
        let info = game.node(id: id)
        return "\(info.moveNumber)\(info.isWhiteMove ? "." : "...")\(info.san)"
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

    /// Plays from/to; a promotion opens the piece picker instead of moving.
    func play(from: Int, to: Int) {
        let matches = legalMoves.filter { squareIndex($0.from) == from && squareIndex($0.to) == to }
        guard let move = matches.first else { return }
        if move.promotion != nil {
            pendingPromotion = PromotionRequest(from: from, to: to, isWhite: whiteToMove)
            return
        }
        playSan(move.san)
    }

    func promote(to letter: String) {
        guard let req = pendingPromotion else { return }
        pendingPromotion = nil
        let move = legalMoves.first {
            squareIndex($0.from) == req.from && squareIndex($0.to) == req.to && $0.promotion == letter
        }
        if let move { playSan(move.san) }
    }

    func cancelPromotion() { pendingPromotion = nil }

    /// Inserts an engine line as a variation from the current node without
    /// moving the cursor (ChessBase kibitzer-copy behavior). Reuses existing
    /// nodes when the moves are already in the tree.
    func insertEngineLine(_ sans: [String]) {
        guard !sans.isEmpty else { return }
        snapshot()
        do {
            var node = currentNode
            for san in sans {
                node = try game.addMove(id: node, san: san)
            }
            rebuildTokens()
        } catch {
            errorText = "\(error)"
        }
    }

    /// Plays a SAN move from the current position (opening-tree click):
    /// advances the cursor, creating a variation when off the mainline.
    func play(san: String) { playSan(san) }

    // --- M5 editing (every op rebuilds tokens; dirty tracking is the
    // baseline comparison, so nothing extra to maintain) ---

    /// Sets a NAG with ChessBase-like semantics: move NAGs ($1–$6) replace
    /// each other, eval NAGs ($7–$19) replace each other, and applying the
    /// same NAG again removes it.
    func applyNag(_ nag: UInt8) {
        guard currentNode != 0 else { return }
        snapshot()
        let existing = [UInt8](game.node(id: currentNode).nags)
        let sameClass: (UInt8) -> Bool = switch nag {
        case 1...6: { (1...6).contains($0) }
        case 7...19: { (7...19).contains($0) }
        default: { $0 == nag }
        }
        var kept = existing.filter { !sameClass($0) }
        if !existing.contains(nag) { kept.append(nag) }
        game.clearNags(id: currentNode)
        for n in kept { game.addNag(id: currentNode, nag: n) }
        rebuildTokens()
    }

    func clearNags() {
        guard currentNode != 0 else { return }
        snapshot()
        game.clearNags(id: currentNode)
        rebuildTokens()
    }

    /// Promotes the variation containing the current move one level up.
    func promoteCurrentVariation() {
        guard currentNode != 0 else { return }
        snapshot()
        game.promoteVariation(id: currentNode)
        rebuildTokens()
    }

    /// Deletes the current move and everything after it; the cursor moves
    /// to the parent. Caller confirms first (destructive).
    func deleteCurrentSubtree() {
        guard currentNode != 0 else { return }
        snapshot()
        let parent = game.node(id: currentNode).parent ?? 0
        game.deleteNode(id: currentNode)
        rebuildTokens()
        select(parent)
    }

    // --- comment editor (popover per NOTATION-VIEW.md: no inline editing) ---

    /// Non-nil while the comment editor is open; bound to its TextEditor.
    var commentDraft: String?
    var commentEditorOpen: Bool { commentDraft != nil }

    func openCommentEditor() {
        guard currentNode != 0 else { return }
        commentDraft = game.node(id: currentNode).comment ?? ""
    }

    func commitComment() {
        guard let draft = commentDraft, currentNode != 0 else {
            commentDraft = nil
            return
        }
        commentDraft = nil
        snapshot()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        game.setComment(id: currentNode, comment: text.isEmpty ? nil : text)
        rebuildTokens()
    }

    func cancelComment() { commentDraft = nil }

    /// "12.Nf3" / "12...c5" — label of the current move for UI titles.
    var currentMoveLabel: String {
        guard currentNode != 0 else { return "" }
        let info = game.node(id: currentNode)
        return "\(info.moveNumber)\(info.isWhiteMove ? "." : "...")\(info.san)"
    }

    private func playSan(_ san: String) {
        snapshot()
        do {
            let node = try game.addMove(id: currentNode, san: san)
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

    // --- session registry (for the quit-time unsaved-changes check) ---

    @MainActor
    final class SessionRegistry {
        static let shared = SessionRegistry()
        private struct WeakBox { weak var session: GameSession? }
        private var boxes: [WeakBox] = []

        func register(_ session: GameSession) {
            boxes.removeAll { $0.session == nil }
            boxes.append(WeakBox(session: session))
        }

        /// Live sessions with unsaved changes to a database game.
        var modified: [GameSession] {
            boxes.compactMap(\.session).filter { $0.sourceGameId >= 0 && $0.isModified }
        }

        /// The opened list is being replaced: no session id is valid anymore.
        func detachAll() {
            for box in boxes { box.session?.detachFromDatabase() }
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
