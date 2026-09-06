import SwiftUI
#if canImport(DanceChessCore)
import DanceChessCore
#endif

/// Reference mode (ChessBase-style): move statistics for the current
/// position across the open list. While visible it also filters the bottom
/// game list to the games reaching the position.
@Observable
@MainActor
final class OpeningTreeModel {
    private(set) var visible = false
    private(set) var rows: [TreeMove] = []
    private(set) var source: ReferenceSource = AppSettings.shared.referenceSource
    private(set) var loading = false
    private(set) var errorText: String?
    /// Online sources: "C41 Philidor Defense", and the position's game count.
    private(set) var openingName: String?
    private(set) var onlineTotal: UInt32 = 0
    private(set) var fromCache = false

    private var fen = ""
    private var generation = 0
    private var pending: Task<Void, Never>?

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
        pending?.cancel()
        rows = []
        errorText = nil
        openingName = nil
        DatabaseStore.shared.setPositionFilter(nil)
    }

    func setSource(_ source: ReferenceSource) {
        guard source != self.source else { return }
        self.source = source
        AppSettings.shared.referenceSource = source
        rows = []
        errorText = nil
        openingName = nil
        if visible { update(fen: fen, immediate: true) }
    }

    /// Refreshes stats for the position. The local list filter is always
    /// the open database (that is what the bottom pane shows); the rows
    /// come from the chosen source. Online sources are debounced: stepping
    /// through moves must not fire a request per keypress.
    func update(fen: String, immediate: Bool = false) {
        guard visible else { return }
        self.fen = fen
        DatabaseStore.shared.setPositionFilter(fen)
        generation += 1
        let gen = generation
        pending?.cancel()
        switch source {
        case .database:
            loading = false
            errorText = nil
            openingName = nil
            rows = (try? DatabaseStore.shared.db?.openingTree(fen: fen)) ?? []
        default:
            let src = source
            pending = Task { @MainActor in
                if !immediate {
                    try? await Task.sleep(for: .milliseconds(300))
                    if Task.isCancelled || gen != generation { return }
                }
                loading = true
                errorText = nil
                do {
                    let result = try await LichessExplorer.shared.fetch(
                        source: src, fen: fen, settings: AppSettings.shared)
                    guard gen == generation else { return }
                    rows = result.rows
                    onlineTotal = result.total
                    openingName = result.opening
                    fromCache = result.cached
                    Self.debugDump(source: src, fen: fen, result: result)
                } catch is CancellationError {
                    return
                } catch {
                    guard gen == generation else { return }
                    rows = []
                    errorText = "\(error)"
                    if let path = ProcessInfo.processInfo.environment["DCS_AUTO_TREE_OUT"] {
                        try? "source: \(src.rawValue)\nerror: \(error)\n"
                            .write(toFile: path, atomically: true, encoding: .utf8)
                    }
                }
                loading = false
            }
        }
    }

    /// DCS_AUTO_TREE_OUT=<file>: what the panel got, for a smoke run.
    private static func debugDump(source: ReferenceSource, fen: String, result: ExplorerResult) {
        guard let path = ProcessInfo.processInfo.environment["DCS_AUTO_TREE_OUT"] else { return }
        let lines = result.rows.prefix(6).map {
            "\($0.san) \($0.games) \($0.whiteWins)/\($0.draws)/\($0.blackWins)"
        }
        let text = "source: \(source.rawValue)\nfen: \(fen)\ncached: \(result.cached)\n"
            + "total: \(result.total)\nopening: \(result.opening ?? "-")\n"
            + lines.joined(separator: "\n") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// One row per continuation: move, game count, score from White's side,
/// W/D/L. Click plays the move (variation if off the mainline).
struct OpeningTreePanel: View {
    let tree: OpeningTreeModel
    let session: GameSession
    @State private var showSettings = false

    private var statusText: String {
        let local = "\(DatabaseStore.shared.matchedCount) in list"
        switch tree.source {
        case .database:
            return "\(DatabaseStore.shared.matchedCount) games reach this position"
        default:
            var parts = ["\(tree.onlineTotal) games"]
            if let name = tree.openingName { parts.append(name) }
            parts.append(local)
            return parts.joined(separator: " · ")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { tree.source },
                                              set: { tree.setSource($0) })) {
                    ForEach(ReferenceSource.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 280)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if tree.loading {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("lichess settings: player username, rating band, speeds")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    LichessSettingsView(tree: tree, session: session)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            if let error = tree.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            } else if tree.rows.isEmpty && !tree.loading {
                Text(tree.source == .database ? "No games continue from here"
                                              : "No games at this position")
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


/// The lichess bits: the user's API token (required — the explorer no
/// longer answers anonymous requests), a username for the Player source,
/// and the rating band and speeds the Lichess source is filtered to.
struct LichessSettingsView: View {
    let tree: OpeningTreeModel
    let session: GameSession
    @State private var settings = AppSettings.shared
    @State private var token = AppSettings.shared.lichessToken ?? ""

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("API token").gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 3) {
                    SecureField("your lichess.org token", text: $token)
                        .frame(width: 200)
                        .onSubmit { saveToken() }
                    HStack(spacing: 6) {
                        Link("Create a read-only token…", destination: AppSettings.tokenURL)
                            .font(.caption)
                        if token != (settings.lichessToken ?? "") {
                            Button("Save") { saveToken() }.controlSize(.mini)
                        }
                    }
                    Text("Required by lichess's explorer. Yours alone, kept in the Keychain.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Player")
                TextField("lichess username", text: $settings.lichessUsername)
                    .frame(width: 200)
                    .onSubmit { refresh() }
            }
            GridRow {
                Text("Ratings")
                Picker("", selection: $settings.lichessRatings) {
                    ForEach(AppSettings.ratingPresets, id: \.1) { preset in
                        Text(preset.0).tag(preset.1)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .onChange(of: settings.lichessRatings) { refresh() }
            }
            GridRow {
                Text("Speeds")
                HStack(spacing: 10) {
                    ForEach(["bullet", "blitz", "rapid", "classical"], id: \.self) { speed in
                        Toggle(speed, isOn: Binding(
                            get: { settings.lichessSpeeds.split(separator: ",").contains(Substring(speed)) },
                            set: { on in
                                var set = Set(settings.lichessSpeeds.split(separator: ",").map(String.init))
                                if on { set.insert(speed) } else { set.remove(speed) }
                                let order = ["bullet", "blitz", "rapid", "classical"]
                                settings.lichessSpeeds = order.filter(set.contains).joined(separator: ",")
                                refresh()
                            }))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            GridRow {
                Text("")
                Text("Results are cached per position; stepping through moves does not re-ask.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
        .padding(12)
        .frame(width: 330)
    }

    private func refresh() {
        tree.update(fen: session.fen, immediate: true)
    }

    private func saveToken() {
        settings.setLichessToken(token)
        refresh()
    }
}
