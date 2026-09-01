import SwiftUI
#if canImport(MacBaseCore)
import MacBaseCore
#endif

/// Horizontal evaluation bar under the board (ChessBase style): white's
/// share grows from the left, the number sits beside it.
struct EvalBar: View {
    /// White-perspective centipawns; nil = no data yet.
    let whiteCp: Int?
    let scoreText: String?

    private var whiteShare: Double {
        guard let whiteCp else { return 0.5 }
        // classic elo-expectation curve; ±400cp ≈ 90/10 split
        return 1 / (1 + pow(10, -Double(whiteCp) / 400))
    }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(white: 0.18))
                    Rectangle()
                        .fill(Color(white: 0.92))
                        .frame(width: geo.size.width * whiteShare)
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.4)))
            .animation(.easeOut(duration: 0.25), value: whiteShare)

            Text(scoreText ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// MultiPV analysis panel below the notation: one row per engine line,
/// click inserts the first move as a variation, ⌥-click the whole line.
struct EnginePanel: View {
    let engine: EngineSession
    let session: GameSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error = engine.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
            if engine.awaitingSelection && engine.errorText == nil {
                Text("Select a move to analyze")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            rows
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(engine.engineName.isEmpty ? "Engine" : engine.engineName)
                .font(.caption.bold())
            if engine.enabled {
                Text("depth \(engine.depth) · \(npsText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button {
                engine.setMultiPV(engine.multiPV - 1)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(engine.multiPV <= 1)
            Text("\(engine.multiPV) lines")
                .font(.caption)
                .monospacedDigit()
            Button {
                engine.setMultiPV(engine.multiPV + 1)
            } label: {
                Image(systemName: "plus")
            }
            .disabled(engine.multiPV >= 8)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(engine.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.scoreText)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                    Text(line.text)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    let wholeLine = NSEvent.modifierFlags.contains(.option)
                    session.insertEngineLine(wholeLine ? line.sans
                                                       : Array(line.sans.prefix(1)))
                }
                .help("Click to insert the first move as a variation; ⌥-click to insert the whole line")
            }
        }
    }

    private var npsText: String {
        let nps = engine.nps
        if nps >= 1_000_000 { return String(format: "%.1fM n/s", Double(nps) / 1_000_000) }
        if nps >= 1_000 { return String(format: "%.0fk n/s", Double(nps) / 1_000) }
        return "\(nps) n/s"
    }
}
