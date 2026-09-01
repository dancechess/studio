import SwiftUI
// under SPM the bindings live in their own module; in the Xcode project
// everything is one target and this import compiles away
#if canImport(MacBaseCore)
import MacBaseCore
#endif

/// M0 bridge check: drives the Rust `Game` object from SwiftUI.
/// Click legal moves to play through a game; the whole round-trip
/// (position, SAN generation, variation tree) runs in Rust.
struct ContentView: View {
    @State private var game = Game()
    @State private var currentNode: UInt32 = 0
    @State private var fen: String = startFen()
    @State private var legalMoves: [String] = []
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacBase — M0 bridge check")
                .font(.headline)
            Text(fen)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 6) {
                    ForEach(legalMoves, id: \.self) { san in
                        Button(san) { play(san) }
                    }
                }
            }

            HStack {
                Button("Back") { goBack() }
                    .disabled(currentNode == 0)
                Button("Reset") { reset() }
                Spacer()
                Text(pgnPreview)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.head)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { refresh() }
    }

    private var pgnPreview: String {
        game.toPgn().replacingOccurrences(of: "\n", with: " ")
    }

    private func play(_ san: String) {
        do {
            currentNode = try game.addMove(id: currentNode, san: san)
            refresh()
        } catch {
            errorText = "\(error)"
        }
    }

    private func goBack() {
        if let parent = game.node(id: currentNode).parent {
            currentNode = parent
            refresh()
        }
    }

    private func reset() {
        game = Game()
        currentNode = 0
        refresh()
    }

    private func refresh() {
        do {
            fen = try game.fenAt(id: currentNode)
            legalMoves = try game.legalMovesAt(id: currentNode)
            errorText = nil
        } catch {
            errorText = "\(error)"
        }
    }
}
