import SwiftUI
#if canImport(MacBaseCore)
import MacBaseCore
#endif

/// Reference mode (ChessBase-style): move statistics for the current
/// position across the open list. While visible it also filters the bottom
/// game list to the games reaching the position.
@Observable
@MainActor
final class OpeningTreeModel {
    private(set) var visible = false
    private(set) var rows: [TreeMove] = []

    func toggle(fen: String) {
        visible.toggle()
        if visible {
            update(fen: fen)
        } else {
            hide()
        }
    }

    func hide() {
        visible = false
        rows = []
        DatabaseStore.shared.setPositionFilter(nil)
    }

    /// Refreshes stats + list filter for the position (fast: zobrist index).
    func update(fen: String) {
        guard visible, let db = DatabaseStore.shared.db else { return }
        rows = (try? db.openingTree(fen: fen)) ?? []
        DatabaseStore.shared.setPositionFilter(fen)
    }
}

/// One row per continuation: move, game count, score from White's side,
/// W/D/L. Click plays the move (variation if off the mainline).
struct OpeningTreePanel: View {
    let tree: OpeningTreeModel
    let session: GameSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Reference")
                    .font(.caption.bold())
                Text("\(DatabaseStore.shared.matchedCount) games reach this position")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            if tree.rows.isEmpty {
                Text("No games continue from here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tree.rows, id: \.san) { row in
                        moveRow(row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func moveRow(_ row: TreeMove) -> some View {
        HStack(spacing: 8) {
            Text(row.san)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 56, alignment: .leading)
            Text("\(row.games)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            scoreBar(row)
                .frame(height: 12)
            Text(scoreText(row))
                .font(.system(size: 11))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { session.play(san: row.san) }
        .help("\(row.whiteWins) wins · \(row.draws) draws · \(row.blackWins) losses (White's view) — click to play")
    }

    /// W/D/L split bar, White's perspective (unknown results excluded).
    private func scoreBar(_ row: TreeMove) -> some View {
        GeometryReader { geo in
            let decided = max(row.whiteWins + row.draws + row.blackWins, 1)
            let w = geo.size.width
            HStack(spacing: 0) {
                Rectangle().fill(Color(white: 0.92))
                    .frame(width: w * CGFloat(row.whiteWins) / CGFloat(decided))
                Rectangle().fill(Color(white: 0.6))
                    .frame(width: w * CGFloat(row.draws) / CGFloat(decided))
                Rectangle().fill(Color(white: 0.18))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary.opacity(0.3)))
    }

    private func scoreText(_ row: TreeMove) -> String {
        let decided = row.whiteWins + row.draws + row.blackWins
        guard decided > 0 else { return "—" }
        let score = (Double(row.whiteWins) + Double(row.draws) / 2) / Double(decided)
        return String(format: "%.0f%%", score * 100)
    }
}
