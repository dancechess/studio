import SwiftUI
import UniformTypeIdentifiers
#if canImport(MacBaseCore)
import MacBaseCore
#endif

struct GameWindow: View {
    @State private var session = GameSession()
    @State private var showImporter = false

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                BoardView(session: session)
                if let error = session.errorText {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .padding(12)
            .frame(minWidth: 360, minHeight: 360)

            VStack(alignment: .leading, spacing: 0) {
                Text(session.gameTitle)
                    .font(.headline)
                    .padding(10)
                Divider()
                NotationView(session: session)
            }
            .frame(minWidth: 280)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { session.back(); return .handled }
        .onKeyPress(.rightArrow) { session.forward(); return .handled }
        .onKeyPress(.upArrow) { session.toStart(); return .handled }
        .onKeyPress(.downArrow) { session.toEnd(); return .handled }
        .toolbar {
            ToolbarItemGroup {
                Button("Open PGN", systemImage: "folder") { showImporter = true }
                Button("Paste PGN", systemImage: "doc.on.clipboard") { pastePgn() }
                Spacer()
                Button("Start", systemImage: "backward.end") { session.toStart() }
                Button("Back", systemImage: "chevron.backward") { session.back() }
                Button("Forward", systemImage: "chevron.forward") { session.forward() }
                Button("End", systemImage: "forward.end") { session.toEnd() }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "pgn") ?? .plainText, .plainText]
        ) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let pgn = try? String(contentsOf: url, encoding: .utf8) {
                session.loadPgn(pgn)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    private func pastePgn() {
        if let pgn = NSPasteboard.general.string(forType: .string) {
            session.loadPgn(pgn)
        }
    }
}
