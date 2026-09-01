import SwiftUI
#if canImport(MacBaseCore)
import MacBaseCore
#endif

/// ChessBase-style "save mask": the game's header fields. Used both to
/// save a newly entered game into the list and to edit an existing game's
/// info (⌘I) — in both cases Save applies the headers and runs `onSave`.
struct GameInfoSheet: View {
    let session: GameSession
    let listName: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var white = ""
    @State private var black = ""
    @State private var whiteElo = ""
    @State private var blackElo = ""
    @State private var event = ""
    @State private var site = ""
    @State private var date = ""
    @State private var round = ""
    @State private var result = "*"

    private static let results = ["*", "1-0", "1/2-1/2", "0-1"]

    private var isNewGame: Bool { session.sourceGameId < 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNewGame ? "Save Game to “\(listName)”" : "Game Info")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    label("White")
                    TextField("", text: $white)
                    label("Elo")
                    TextField("", text: $whiteElo).frame(width: 64)
                }
                GridRow {
                    label("Black")
                    TextField("", text: $black)
                    label("Elo")
                    TextField("", text: $blackElo).frame(width: 64)
                }
                GridRow {
                    label("Result")
                    Picker("", selection: $result) {
                        ForEach(Self.results, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .gridCellColumns(3)
                }
                GridRow {
                    label("Event")
                    TextField("", text: $event).gridCellColumns(3)
                }
                GridRow {
                    label("Site")
                    TextField("", text: $site).gridCellColumns(3)
                }
                GridRow {
                    label("Date")
                    TextField("YYYY.MM.DD", text: $date)
                    label("Round")
                    TextField("", text: $round).frame(width: 64)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    apply()
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: prefill)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func prefill() {
        white = session.game.header(key: "White") ?? ""
        black = session.game.header(key: "Black") ?? ""
        whiteElo = session.game.header(key: "WhiteElo") ?? ""
        blackElo = session.game.header(key: "BlackElo") ?? ""
        event = session.game.header(key: "Event") ?? ""
        site = session.game.header(key: "Site") ?? ""
        round = session.game.header(key: "Round") ?? ""
        if let r = session.game.header(key: "Result"), Self.results.contains(r) {
            result = r
        }
        date = session.game.header(key: "Date") ?? Self.today()
    }

    private func apply() {
        // Result always (it doubles as the PGN termination marker); the
        // rest only when filled — no "[Event \"\"]" noise in the file
        var pairs: [(String, String)] = [("Result", result)]
        for (key, value) in [("White", white), ("Black", black),
                             ("WhiteElo", whiteElo), ("BlackElo", blackElo),
                             ("Event", event), ("Site", site),
                             ("Date", date), ("Round", round)]
        where !value.trimmingCharacters(in: .whitespaces).isEmpty {
            pairs.append((key, value.trimmingCharacters(in: .whitespaces)))
        }
        session.setHeaders(pairs)
    }

    /// PGN date format, locale-independent (see ARCHITECTURE.md).
    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: Date())
    }
}
