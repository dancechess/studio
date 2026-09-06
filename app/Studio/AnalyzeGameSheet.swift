import SwiftUI

/// Options + progress for the whole-game analysis (Game ▸ Analyze Game…).
/// Thresholds are centipawns lost by the mover; the defaults match what
/// most tools call inaccuracy / mistake / blunder.
struct AnalyzeGameSheet: View {
    let session: GameSession
    let analyzer: GameAnalyzer
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AnalysisSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analyze Game").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Depth").gridColumnAlignment(.trailing)
                    Stepper(value: $settings.depth, in: 8...30) {
                        Text("\(settings.depth)").monospacedDigit().frame(width: 28, alignment: .leading)
                    }
                }
                GridRow {
                    Text("Inaccuracy ?!")
                    cp($settings.inaccuracy)
                }
                GridRow {
                    Text("Mistake ?")
                    cp($settings.mistake)
                }
                GridRow {
                    Text("Blunder ??")
                    cp($settings.blunder)
                }
                GridRow {
                    Text("Line")
                    Stepper(value: $settings.lineLength, in: 1...12) {
                        Text("\(settings.lineLength) plies").frame(width: 60, alignment: .leading)
                    }
                }
            }
            .disabled(analyzer.running)
            Text("Main line only. Marks, evals and engine lines land in one undo step; existing comments are kept.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if analyzer.running {
                ProgressView(value: Double(analyzer.done), total: Double(max(1, analyzer.total))) {
                    Text("\(analyzer.currentLabel)  ·  \(analyzer.done) / \(analyzer.total)")
                        .font(.caption).monospacedDigit()
                }
            } else if let text = analyzer.summary {
                Text(text).font(.caption)
            }
            if let error = analyzer.errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if analyzer.running {
                    Button("Cancel") { analyzer.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else if analyzer.summary != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Analyze") {
                        onStart()
                        Task { await analyzer.run(session: session, settings: settings) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.game.mainline().isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func cp(_ value: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 60)
            Text("cp").foregroundStyle(.secondary)
        }
    }
}
