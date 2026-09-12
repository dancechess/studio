import AppKit
import SwiftUI

/// The Settings window (⌘,). Everything here is about how the app looks to
/// one reader on one Mac, which is why it lives in preferences rather than
/// in a file: a notation panel is stared at for an hour at a time, and the
/// size that suits a 27-inch display at arm's length is not the size that
/// suits a laptop on a train.
///
/// The preview is the point. A font popup that only shows font *names*
/// makes the reader open and close this window once per candidate; showing
/// a real line of notation in the chosen face answers the question in
/// place.
struct SettingsView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Notation") {
                Picker("Typeface", selection: Binding(
                    get: { settings.notationFace },
                    set: { settings.notationFace = $0 })) {
                    ForEach(NotationFace.allCases) { face in
                        Text("\(face.label) — \(face.note)").tag(face)
                    }
                }

                let size = settings.notationFontSize
                LabeledContent("Size") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { size },
                                              set: { settings.setNotationFontSize($0) }),
                               in: AppSettings.fontSizeRange, step: 1)
                        Text("\(Int(size)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .help("Engine lines and the opening tree follow this size too.")

                Toggle("Figurine notation (♘f3)", isOn: Binding(
                    get: { settings.figurines },
                    set: { settings.figurines = $0 }))
                .help("Off by default: ChessBase shows Nf3, and the PGN always keeps the letter.")

                LabeledContent("Preview") {
                    NotationSample(face: settings.notationFace,
                                   size: settings.notationFontSize,
                                   figurines: settings.figurines)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A line of notation in the chosen face: main line, a variation, a
/// comment — the three things the panel actually renders, so a choice can
/// be judged on contrast and not just on shape.
private struct NotationSample: View {
    let face: NotationFace
    let size: Double
    let figurines: Bool

    var body: some View {
        let main = Font(face.font(size: size, weight: .semibold))
        let sub = Font(face.font(size: size - 1))
        return VStack(alignment: .leading, spacing: 3) {
            (Text(moves("1. e4 e5 2. Nf3 Nc6 3. Bb5 a6")).font(main)
                + Text("  ")
                + Text(moves("(3... Nf6 4. O-O Nxe4)")).font(sub).foregroundColor(.secondary))
            Text("The Spanish: White trades the threat of Bxc6 for time.")
                .font(sub)
                .foregroundColor(.green)
        }
        .textSelection(.disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func moves(_ line: String) -> String {
        guard figurines else { return line }
        return line.split(separator: " ", omittingEmptySubsequences: false)
            .map { NotationView.figurine(String($0)) }
            .joined(separator: " ")
    }
}
