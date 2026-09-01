import SwiftUI
import AppKit
#if canImport(MacBaseCore)
import MacBaseCore
#endif

/// Handle the main window keeps on the table for cross-pane coordination
/// (⌘↑↓ game switching, focus hand-off, click-zone hit testing).
@MainActor
final class GameListController {
    weak var coordinator: GameListView.Coordinator?
    var scrollView: NSScrollView? { coordinator?.scrollView }
    func selectRelative(_ delta: Int) { coordinator?.selectRelative(delta) }
    func focusTable() { coordinator?.focusTable() }
    /// Clears the selection without callbacks (in-window new-game entry).
    func deselect() { coordinator?.deselectQuietly() }
    /// Pins the selection to a game id without reloading it (already shown).
    func select(id: Int64) { coordinator?.selectQuietly(id: id) }
    /// The selected game's id, if any (delete-key handling).
    var selectedGameId: Int64? { coordinator?.currentSelectedId }
}

/// The game list: an NSTableView (SwiftUI `Table` chokes on 100k rows) with
/// SQLite-paged lazy loading. Rows come from `DatabaseStore.page()` in
/// fixed-size pages cached by the coordinator; a `revision` bump (sort
/// change, import, save-back) drops the cache, reloads, and re-pins the
/// selection by game id. Selection drives the board preview; leaving a
/// modified game is gated by `shouldLeaveGame` (save prompt).
struct GameListView: NSViewRepresentable {
    let store: DatabaseStore
    // read in the parent's body so SwiftUI re-runs updateNSView on change
    let revision: Int
    let generation: Int
    let count: UInt64
    let controller: GameListController
    /// Save-prompt gate; returning false keeps the current selection.
    let shouldLeaveGame: () -> Bool
    /// Selection landed on this game (load it into the board preview).
    let onSelect: (Int64) -> Void
    /// Double-click; `commandKey` distinguishes ⌘-double-click.
    let onActivate: (Int64, _ commandKey: Bool) -> Void
    /// Right-click → Delete Game… (nil disables the menu item).
    let onDeleteRequest: ((Int64) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(view: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 22

        for spec in Coordinator.columns {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 40
            if let key = spec.sortKey {
                column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            }
            table.addTableColumn(column)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        let delete = NSMenuItem(title: "Delete Game…",
                                action: #selector(Coordinator.deleteClicked(_:)),
                                keyEquivalent: "")
        delete.target = context.coordinator
        menu.addItem(delete)
        table.menu = menu
        // initial sort indicator mirrors the store (file order)
        table.sortDescriptors = [NSSortDescriptor(key: "number", ascending: true)]
        context.coordinator.table = table
        controller.coordinator = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.scrollView = scroll
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.view = self
        controller.coordinator = coordinator
        if coordinator.generation != generation {
            // a different list: drop the pinned selection so row 0 of the
            // new list gets selected and loaded fresh
            coordinator.generation = generation
            coordinator.resetForNewList()
        }
        if coordinator.revision != revision || coordinator.count != count {
            coordinator.revision = revision
            coordinator.count = count
            coordinator.dropCacheAndReload()
        }
        coordinator.selectInitialRowIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct ColumnSpec {
            let id: String
            let title: String
            let width: CGFloat
            let sortKey: String? // nil = not sortable (no GameSort case)
        }

        // sortKey strings map to GameSort below
        static let columns: [ColumnSpec] = [
            // game number = id = position in the opened file; the label
            // travels with the game under any sort
            ColumnSpec(id: "number", title: "#", width: 42, sortKey: "number"),
            ColumnSpec(id: "white", title: "White", width: 150, sortKey: "white"),
            ColumnSpec(id: "whiteElo", title: "Elo", width: 46, sortKey: "whiteElo"),
            ColumnSpec(id: "black", title: "Black", width: 150, sortKey: "black"),
            ColumnSpec(id: "blackElo", title: "Elo", width: 46, sortKey: nil),
            ColumnSpec(id: "result", title: "Result", width: 52, sortKey: nil),
            ColumnSpec(id: "round", title: "Round", width: 48, sortKey: "round"),
            ColumnSpec(id: "moves", title: "Moves", width: 44, sortKey: nil),
            ColumnSpec(id: "eco", title: "ECO", width: 46, sortKey: "eco"),
            ColumnSpec(id: "event", title: "Event", width: 170, sortKey: "event"),
            ColumnSpec(id: "date", title: "Date", width: 86, sortKey: "date"),
        ]

        private static let pageSize: UInt64 = 256
        /// After a reload, how far to scan for the previously selected id
        /// (beyond this the selection is simply dropped).
        private static let reselectScanLimit = 2048

        var view: GameListView
        weak var table: NSTableView?
        weak var scrollView: NSScrollView?
        var revision = 0
        var generation = 0
        var count: UInt64 = 0
        private var pages: [UInt64: [GameSummary]] = [:]
        private var selectedId: Int64?
        private var selectedRow = -1
        /// Quiets delegate callbacks during programmatic re-selection.
        private var reselecting = false
        private var didInitialSelect = false
        /// Startup-only: restore the last-viewed game once, then never again
        /// (a replaced list must not inherit it).
        private var pendingInitialId: Int64? = UserDefaults.standard
            .object(forKey: DatabaseStore.lastSelectedGameKey) as? Int64

        init(view: GameListView) {
            self.view = view
            self.count = view.count
            self.revision = view.revision
            self.generation = view.generation
        }

        func resetForNewList() {
            selectedId = nil
            selectedRow = -1
            didInitialSelect = false
            pendingInitialId = nil // only the startup list restores it
        }

        func deselectQuietly() {
            reselecting = true
            defer { reselecting = false }
            table?.deselectAll(nil)
            selectedId = nil
            selectedRow = -1
        }

        func selectQuietly(id: Int64) {
            selectedId = id
            // appended games sit on the last row under the default number
            // sort — try that hint before the bounded scan
            selectedRow = count > 0 ? Int(count) - 1 : -1
            reselectPreviousId()
        }

        func dropCacheAndReload() {
            pages.removeAll()
            table?.reloadData()
            reselectPreviousId()
        }

        /// Pins the selection to the same game after a reload: the old row
        /// index first (sorts are mostly stable), then a bounded scan.
        private func reselectPreviousId() {
            guard let table, let id = selectedId else { return }
            reselecting = true
            defer { reselecting = false }
            var target: Int?
            if selectedRow >= 0, summary(at: selectedRow)?.id == id {
                target = selectedRow
            } else {
                for row in 0..<min(Int(count), Self.reselectScanLimit)
                where summary(at: row)?.id == id {
                    target = row
                    break
                }
            }
            if let target {
                table.selectRowIndexes([target], byExtendingSelection: false)
                table.scrollRowToVisible(target)
                selectedRow = target
            } else {
                table.deselectAll(nil)
                selectedId = nil
                selectedRow = -1
            }
        }

        func selectInitialRowIfNeeded() {
            guard !didInitialSelect, count > 0, let table else { return }
            didInitialSelect = true
            var row = 0
            if let id = pendingInitialId {
                pendingInitialId = nil
                for probe in 0..<min(Int(count), Self.reselectScanLimit)
                where summary(at: probe)?.id == id {
                    row = probe
                    break
                }
            }
            // unsuppressed: selectionDidChange fires and loads the game
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            focusTable()
        }

        func selectRelative(_ delta: Int) {
            guard let table, count > 0 else { return }
            let current = table.selectedRow
            let next = min(max(current + delta, 0), Int(count) - 1)
            guard next != current else { return }
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
        }

        func focusTable() {
            if let table { table.window?.makeFirstResponder(table) }
        }

        private func summary(at row: Int) -> GameSummary? {
            let page = UInt64(row) / Self.pageSize
            if pages[page] == nil {
                pages[page] = view.store.page(offset: page * Self.pageSize,
                                              limit: UInt32(Self.pageSize))
            }
            let rows = pages[page] ?? []
            let index = row - Int(page * Self.pageSize)
            return rows.indices.contains(index) ? rows[index] : nil
        }

        // MARK: data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { Int(count) }

        func selectionShouldChange(in tableView: NSTableView) -> Bool {
            // user-initiated only (clicks, arrow keys) — the save-prompt gate
            reselecting || view.shouldLeaveGame()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !reselecting, let table, table.selectedRow >= 0,
                  let game = summary(at: table.selectedRow) else { return }
            selectedId = game.id
            selectedRow = table.selectedRow
            view.onSelect(game.id)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let id = tableColumn?.identifier else { return nil }
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let field = NSTextField(labelWithString: "")
                field.font = .systemFont(ofSize: 12)
                if id.rawValue == "number" {
                    field.alignment = .right
                    field.textColor = .secondaryLabelColor
                }
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            guard let game = summary(at: row) else {
                cell.textField?.stringValue = ""
                return cell
            }
            cell.textField?.stringValue = text(for: id.rawValue, game: game)
            return cell
        }

        private func text(for column: String, game: GameSummary) -> String {
            switch column {
            case "number": String(game.id)
            case "white": game.white
            case "whiteElo": game.whiteElo.map(String.init) ?? ""
            case "black": game.black
            case "blackElo": game.blackElo.map(String.init) ?? ""
            case "result": game.result
            case "round": game.round
            case "moves": String((game.plyCount + 1) / 2)
            case "eco": game.eco
            case "event": game.event
            case "date": game.date
            default: ""
            }
        }

        func tableView(_ tableView: NSTableView,
                       sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key else { return }
            let sort: GameSort? = switch key {
            case "number": .number
            case "round": .round
            case "date": .date
            case "white": .white
            case "black": .black
            case "event": .event
            case "eco": .eco
            case "whiteElo": .whiteElo
            default: nil
            }
            if let sort { view.store.setSort(sort, ascending: descriptor.ascending) }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0,
                  let game = summary(at: table.clickedRow) else { return }
            let command = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            view.onActivate(game.id, command)
        }

        var currentSelectedId: Int64? {
            guard let table, table.selectedRow >= 0 else { return nil }
            return summary(at: table.selectedRow)?.id
        }

        @objc func deleteClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0,
                  let game = summary(at: table.clickedRow) else { return }
            view.onDeleteRequest?(game.id)
        }

        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
            view.onDeleteRequest != nil && (table?.clickedRow ?? -1) >= 0
        }
    }
}
