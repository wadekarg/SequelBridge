//
//  ResultsTableView.swift
//  SequelBridge
//
//  The results grid, backed by AppKit's NSTableView — the same technique Sequel Ace
//  and every fast Mac DB client use. NSTableView is virtualized: only the rows on
//  screen exist as views, and it recycles a small pool of cell views as you scroll.
//  Data is pulled per-cell on demand from the single QueryResult (never copied or
//  re-sorted to scroll), and a fixed row height makes scrolling to any offset O(1).
//
//  This replaces the SwiftUI LazyVStack grid, which rebuilt and re-sorted the whole
//  dataset on every render (every scroll tick and hover) — the cause of the freeze.
//
//  Drop-in API-compatible with the old ResultsGridView.
//

import SwiftUI
import AppKit

/// How a grid's cells are edited. The Content tab edits in the cell, like Sequel Ace;
/// the Query tab opens the value in a popup with Edit and Save. A grid without one
/// (the Server tab's lists) only shows values.
struct CellEditing {
    enum Style { case inCell, popup }
    let style: Style
    /// Why result column `i` can't be edited, or nil when it can.
    let reason: (Int) -> String?
    /// Bumped by the owner after a successful save, so the grid redraws the changed row.
    let revision: Int
    /// Saves one cell: the result's row, column, value (nil = NULL). Returns the error message, or nil.
    let save: (Int, Int, String?) async -> String?
}

struct ResultsTableView: View {
    let result: QueryResult
    var tableName: String? = nil
    var cellEditing: CellEditing? = nil
    var onSelectionChange: ((Set<Int>) -> Void)? = nil
    var onSortChange: ((Int, Bool) -> Void)? = nil

    var body: some View {
        _ResultsTable(
            result: result,
            tableName: tableName,
            cellEditing: cellEditing,
            onSelectionChange: onSelectionChange,
            onSortChange: onSortChange
        )
    }

    /// Signature that decides whether the grid must reload. It includes a content
    /// fingerprint (first + last row), not just the shape (columns/counts/time), so a
    /// Content-browser page change or a server-side re-sort — which keep columns, row
    /// count, total and (placeholder) executionTime identical — still forces a reload.
    /// A shape-only signature left the grid showing stale rows after paging/sorting.
    /// First+last row is O(columns), not O(rows), so it stays cheap while streaming.
    static func reloadSignature(for result: QueryResult) -> String {
        let first = result.row(0).joined(separator: "\u{1}")
        let last  = result.row(result.rowCount - 1).joined(separator: "\u{1}")
        return "\(result.columns.joined(separator: "\u{1}"))|\(result.rowCount)|\(result.totalRowCount)|\(result.executionTime)|\(first)|\(last)"
    }

    /// Pure, testable ordering used for the in-memory (client-side) sort and by tests.
    /// Numeric-looking columns sort numerically; everything else lexicographically.
    static func sortOrder(rows: [[String]], column: Int?, ascending: Bool) -> [Int] {
        guard let col = column else { return Array(rows.indices) }
        return sortOrder(keys: rows.map { $0[safe: col] ?? "" }, ascending: ascending)
    }

    /// The same order, keyed on one column of a cell table (materialized once; most
    /// values are short enough to live inline in a String, so this is cheap even for
    /// millions of rows).
    static func sortOrder(cells: CellTable, column: Int?, ascending: Bool) -> [Int] {
        guard let col = column else { return Array(0..<cells.rowCount) }
        return sortOrder(keys: cells.column(col), ascending: ascending)
    }

    /// Numeric when both keys parse as numbers, string order otherwise.
    private static func sortOrder(keys: [String], ascending: Bool) -> [Int] {
        Array(keys.indices).sorted { i, j in
            let a = keys[i], b = keys[j]
            if let n1 = Double(a), let n2 = Double(b) {
                return ascending ? n1 < n2 : n1 > n2
            }
            return ascending ? a < b : a > b
        }
    }

    /// The grid's display→original row permutation. EMPTY means identity (display row
    /// i is original row i) — the common case, and the one that holds while a result
    /// streams in — so no O(rows) index array is built on every refresh. A server-side
    /// sort already ordered the page, so it is identity too; only a client-side sort
    /// materializes the permutation, via sortOrder.
    static func displayOrder(rows: [[String]], column: Int?, ascending: Bool, isServerSort: Bool) -> [Int] {
        guard let col = column, !isServerSort else { return [] }
        return sortOrder(rows: rows, column: col, ascending: ascending)
    }

    static func displayOrder(cells: CellTable, column: Int?, ascending: Bool, isServerSort: Bool) -> [Int] {
        guard let col = column, !isServerSort else { return [] }
        return sortOrder(cells: cells, column: col, ascending: ascending)
    }

    enum UpdateKind: Equatable { case append, reload }

    /// How the grid should take a new result. A streamed batch only APPENDS rows: same
    /// columns, the rows it already had are unchanged (checked by the first row and the
    /// previous last row, O(columns)), and more rows. Then the table only needs its row
    /// count noted — existing cell views stay. Everything else (a new result, a page
    /// change, a server re-sort, or growth under a client-side sort that must re-sort)
    /// reloads. Reloading discards and rebuilds every visible cell, which was ~45% of
    /// main-thread time while a large result streamed in.
    static func updateKind(from previous: QueryResult?, to current: QueryResult, clientSorted: Bool) -> UpdateKind {
        guard let previous, !clientSorted,
              previous.columns == current.columns,
              previous.rowCount < current.rowCount,
              previous.row(0) == current.row(0),
              previous.row(previous.rowCount - 1) == current.row(previous.rowCount - 1)
        else { return .reload }
        return .append
    }
}

// MARK: - NSViewRepresentable

private struct _ResultsTable: NSViewRepresentable {
    let result: QueryResult
    let tableName: String?
    let cellEditing: CellEditing?
    let onSelectionChange: ((Set<Int>) -> Void)?
    let onSortChange: ((Int, Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coord = context.coordinator
        let table = ResultsNSTableView()
        table.dataSource = coord
        table.delegate = coord
        table.coordinator = coord

        table.rowHeight = Theme.rowHeight
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.3)
        table.style = .plain
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        table.target = coord
        table.intercellSpacing = NSSize(width: 0, height: 0)

        coord.table = table
        coord.buildColumns()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.parent = self                       // refresh callbacks + result
        coord.syncIfNeeded()
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: _ResultsTable
        weak var table: ResultsNSTableView?

        private var signature = ""
        private var editRevision = 0
        private var popover: NSPopover? = nil
        /// The result the table currently shows, for append detection (see updateKind).
        /// Its row arrays share storage with the new result, so this holds little extra.
        private var previousResult: QueryResult? = nil
        private var builtColumns: [String] = []
        private var displayOrder: [Int] = []      // display row -> original result.rows index
        private var sortColumn: Int? = nil
        private var sortAscending = true
        private var lastClickedColumn = 0

        private let cellID = NSUserInterfaceItemIdentifier("cell")
        private let monoFont = Theme.dataNSFont(Theme.dataFontSize)

        init(_ parent: _ResultsTable) { self.parent = parent }

        private var result: QueryResult { parent.result }
        private var isServerSort: Bool { parent.onSortChange != nil }
        /// Why result column `col` can't be edited, or nil when it can.
        private func reason(forColumn col: Int) -> String? {
            guard let editing = parent.cellEditing else { return CellEditability.notEditable }
            return editing.reason(col)
        }

        // Reload only when the result actually changed — see ResultsTableView.reloadSignature.
        private func currentSignature() -> String { ResultsTableView.reloadSignature(for: result) }

        func syncIfNeeded() {
            // A saved edit changes one cell, which the signature (first and last row)
            // doesn't see; the owner bumps the revision instead.
            if let revision = parent.cellEditing?.revision, revision != editRevision {
                editRevision = revision
                // Not under an edit in progress: reloading would take its text field away.
                if inline != nil { reloadAfterEdit = true } else { table?.reloadData() }
            }
            let sig = currentSignature()
            guard sig != signature else { return }
            signature = sig
            let kind = ResultsTableView.updateKind(from: previousResult, to: result,
                                                   clientSorted: sortColumn != nil && !isServerSort)
            previousResult = result
            if result.columns != builtColumns { buildColumns(); return }   // reloads
            // Grow the row-number gutter as more rows stream in — never shrink, so the
            // data columns don't shift around. Data-column widths stay fixed from buildColumns.
            if let numCol = table?.tableColumns.first(where: { $0.identifier.rawValue == "rownum" }) {
                let w = rowNumberWidth(for: result.rowCount)
                if w > numCol.width { numCol.width = w }
            }
            if kind == .append {
                // Streamed rows arrived: tell the table it grew; visible cells stay.
                table?.noteNumberOfRowsChanged()
            } else {
                recomputeOrder()
                table?.reloadData()
            }
        }

        /// Empty `displayOrder` is identity — every lookup already falls back with
        /// `displayOrder[safe: row] ?? row` — so the streaming case (no local sort,
        /// a refresh per flushed batch) never rebuilds an O(rows) index array.
        private func recomputeOrder() {
            displayOrder = ResultsTableView.displayOrder(cells: result.cells, column: sortColumn,
                                                         ascending: sortAscending, isServerSort: isServerSort)
        }

        // MARK: Column auto-sizing (fit to content, capped) — like Sequel Ace

        /// Longest auto width, in characters. A long TEXT/JSON/blob column stops here
        /// (the value truncates with "…"; double-click shows it in full). The user can
        /// still drag wider. Widths are computed once per result — in buildColumns,
        /// which only runs when the columns change — so they don't jump while rows
        /// stream in or pages change.
        private let maxColChars = 48
        private let minColWidth: CGFloat = 50
        /// Cell horizontal padding (both sides) plus a little slack.
        private var colPad: CGFloat { Theme.cellPaddingH * 2 + 6 }

        private func textWidth(_ s: String, font: NSFont) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }

        /// Fit width for a data column: the widest of its header and a sample of its
        /// cells, clamped between the minimum and the character cap.
        private func fittedWidth(column ci: Int, header: String) -> CGFloat {
            let cap = ceil(textWidth(String(repeating: "0", count: maxColChars), font: monoFont)) + colPad
            // Header uses the system header font; leave room for the sort-indicator arrow.
            var w = ceil(textWidth(header, font: NSFont.systemFont(ofSize: 12))) + colPad + 16
            let sampleLimit = min(result.rowCount, 400)
            if sampleLimit > 0 {
                // Track the few longest-by-character values, then measure only those —
                // cheap even on wide results. Stop early once one reaches the cap length,
                // so a column of large blobs doesn't scan every value.
                var c1 = "", c2 = "", c3 = ""
                for r in 0..<sampleLimit {
                    let v = result.cells.value(r, ci)
                    if v.count > c1.count { c3 = c2; c2 = c1; c1 = v }
                    else if v.count > c2.count { c3 = c2; c2 = v }
                    else if v.count > c3.count { c3 = v }
                    if c1.count >= maxColChars + 4 { break }
                }
                for cand in [c1, c2, c3] where !cand.isEmpty {
                    w = max(w, ceil(textWidth(String(cand.prefix(maxColChars + 4)), font: monoFont)) + colPad)
                }
            }
            return min(max(w, minColWidth), cap)
        }

        /// Gutter width for the row-number column, sized to the largest number shown.
        private func rowNumberWidth(for count: Int) -> CGFloat {
            min(max(ceil(textWidth("\(max(count, 1))", font: Theme.dataNSFont(11))) + colPad, 40), 90)
        }

        func buildColumns() {
            guard let table else { return }
            for col in table.tableColumns { table.removeTableColumn(col) }
            builtColumns = result.columns

            let num = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rownum"))
            num.title = "#"
            num.width = rowNumberWidth(for: result.rowCount); num.minWidth = 40; num.maxWidth = 100
            num.headerCell.alignment = .center
            table.addTableColumn(num)

            for (idx, name) in result.columns.enumerated() {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(idx)"))
                // Padded header cell so the column name lines up with the data below it.
                let header = PaddedHeaderCell(textCell: name)
                header.font = col.headerCell.font
                col.headerCell = header
                // Auto-fit to content, capped. minWidth/maxWidth bound manual resizing;
                // the user can drag well past the cap when they want the full value inline.
                col.width = fittedWidth(column: idx, header: name)
                col.minWidth = minColWidth; col.maxWidth = 2000
                let type = result.columnTypes[safe: idx] ?? ""
                if !type.isEmpty { col.headerToolTip = "\(name)  —  \(type.lowercased())" }
                table.addTableColumn(col)
            }
            recomputeOrder()
            table.reloadData()
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { result.rowCount }

        // MARK: Delegate — cell views

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let cell = (tableView.makeView(withIdentifier: cellID, owner: self) as? DataCellView) ?? makeCell()

            let originalRow = displayOrder[safe: row] ?? row

            if tableColumn.identifier.rawValue == "rownum" {
                cell.configureRowNumber(row + 1, font: monoFont)
                return cell
            }
            guard let colIdx = columnIndex(tableColumn) else { return cell }
            let value = result.cells.value(originalRow, colIdx)
            let isNull = result.isNull(originalRow, colIdx)
            let numeric = QueryResult.isNumericType(result.columnTypes[safe: colIdx] ?? "")
            cell.configure(value: isNull ? "NULL" : value, isNull: isNull, numeric: numeric, font: monoFont)
            return cell
        }

        private func makeCell() -> DataCellView {
            let cell = DataCellView.make()
            cell.identifier = cellID
            return cell
        }

        private func columnIndex(_ column: NSTableColumn) -> Int? {
            let raw = column.identifier.rawValue
            guard raw.hasPrefix("c") else { return nil }
            return Int(raw.dropFirst())
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, let cb = parent.onSelectionChange else { return }
            let original = Set(table.selectedRowIndexes.map { displayOrder[safe: $0] ?? $0 })
            cb(original)
        }

        // MARK: Sorting — handle the header click directly (reliable across setups)

        func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
            guard let colIdx = columnIndex(tableColumn) else { return }   // ignore the row-number column
            let ascending = (sortColumn == colIdx) ? !sortAscending : true
            sortColumn = colIdx
            sortAscending = ascending

            for c in tableView.tableColumns { tableView.setIndicatorImage(nil, in: c) }
            tableView.setIndicatorImage(
                NSImage(named: ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"),
                in: tableColumn)
            tableView.highlightedTableColumn = tableColumn

            if isServerSort {
                // Hand the sort to the parent; it reloads an ORDER BY page from the server.
                parent.onSortChange?(colIdx, ascending)
            } else {
                recomputeOrder()
                tableView.reloadData()
            }
        }

        // MARK: Double-click — edit in the cell (Content) or the popup (Query)

        @objc func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow, col = sender.clickedColumn
            guard row >= 0, col >= 0, let colIdx = columnIndex(sender.tableColumns[col]) else { return }
            lastClickedColumn = colIdx
            if parent.cellEditing?.style == .inCell {
                if let reason = reason(forColumn: colIdx) {
                    showHint(reason, row: row, col: col)
                } else {
                    beginInlineEdit(row: row, col: col, colIdx: colIdx)
                }
            } else {
                showPopup(row: row, col: col, colIdx: colIdx)
            }
        }

        /// The value in a popup beside the cell (CellEditorView): Copy and Cancel, plus
        /// Edit and Save where the cell can be edited, or the reason it can't.
        private func showPopup(row: Int, col: Int, colIdx: Int) {
            guard let table else { return }
            let originalRow = displayOrder[safe: row] ?? row
            let reason = reason(forColumn: colIdx)
            let state = CellEditorState(column: result.columns[safe: colIdx] ?? "",
                                        columnType: result.columnTypes[safe: colIdx] ?? "",
                                        value: result.cells.value(originalRow, colIdx),
                                        isNull: result.isNull(originalRow, colIdx),
                                        readOnlyReason: reason)
            let save = parent.cellEditing?.save
            popover?.close()
            let pop = NSPopover()
            pop.behavior = .transient            // a click elsewhere closes it, like Cancel
            pop.animates = false
            // Match the window: the app's own Light/Dark setting, not the system's.
            pop.appearance = table.window?.effectiveAppearance
            pop.contentViewController = NSHostingController(rootView: CellEditorView(
                state: state,
                save: { value in
                    guard let save else { return reason ?? CellEditability.notEditable }
                    return await save(originalRow, colIdx, value)
                },
                close: { [weak pop] in pop?.performClose(nil) }))
            pop.show(relativeTo: table.frameOfCell(atColumn: col, row: row), of: table, preferredEdge: .maxY)
            popover = pop
        }

        /// A short note beside a cell that can't be edited, saying why (Sequel Ace shows a
        /// tooltip there). It closes by itself, or on the next click.
        private func showHint(_ text: String, row: Int, col: Int) {
            guard let table else { return }
            popover?.close()
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 300
            let size = label.fittingSize
            let pad: CGFloat = 10
            let box = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 2 * pad, height: size.height + 2 * pad))
            label.frame = NSRect(x: pad, y: pad, width: size.width, height: size.height)
            box.addSubview(label)
            let controller = NSViewController()
            controller.view = box
            let pop = NSPopover()
            pop.behavior = .transient
            pop.animates = false
            pop.appearance = table.window?.effectiveAppearance
            pop.contentViewController = controller
            pop.show(relativeTo: table.frameOfCell(atColumn: col, row: row), of: table, preferredEdge: .maxY)
            popover = pop
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak pop] in pop?.close() }
        }

        // MARK: In-cell editing (Content tab)

        /// The edit in progress: where it is and what the cell held.
        private struct InlineSession {
            weak var field: NSTextField?
            let displayRow: Int
            let originalRow: Int
            let column: Int          // result column
            let tableColumn: Int     // the table view's column (the row numbers are column 0)
            let original: String     // "" for NULL
            let originalIsNull: Bool
            var cancelled = false
        }
        private var inline: InlineSession? = nil
        /// A saved value arrived while another cell was being edited; redraw when that ends.
        private var reloadAfterEdit = false

        /// Turns the cell into an editor: its value (or `text`), all selected, in the
        /// normal text colour on the text background.
        private func beginInlineEdit(row: Int, col: Int, colIdx: Int, text: String? = nil) {
            guard let table else { return }
            if inline != nil { table.window?.makeFirstResponder(table) }   // finish the edit in progress
            guard let cell = table.view(atColumn: col, row: row, makeIfNecessary: true) as? DataCellView,
                  let tf = cell.textField else { return }
            let originalRow = displayOrder[safe: row] ?? row
            let isNull = result.isNull(originalRow, colIdx)
            let value = isNull ? "" : result.cells.value(originalRow, colIdx)
            inline = InlineSession(field: tf, displayRow: row, originalRow: originalRow, column: colIdx,
                                   tableColumn: col, original: value, originalIsNull: isNull)
            cell.beginInlineEdit(text: text ?? value, placeholder: isNull ? CellTable.nullText : nil, font: monoFont)
            tf.delegate = self
            table.window?.makeFirstResponder(tf)
            tf.currentEditor()?.selectAll(nil)
        }

        /// Return saves, Esc puts the value back; both end the edit.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let edit = inline, control === edit.field else { return false }
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                inline?.cancelled = true
                table?.window?.makeFirstResponder(table)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                table?.window?.makeFirstResponder(table)
                return true
            default:
                return false
            }
        }

        /// The edit ended: Return, Tab, a click elsewhere, or Esc. A change is saved; while
        /// it is written the cell shows it, and a refusal puts the old value back and says why.
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField, let edit = inline, tf === edit.field else { return }
            inline = nil
            let text = tf.stringValue
            (tf.superview as? DataCellView)?.endInlineEdit()
            if reloadAfterEdit { reloadAfterEdit = false; table?.reloadData() }
            switch InlineCellEdit.outcome(original: edit.original, originalIsNull: edit.originalIsNull,
                                          text: text, cancelled: edit.cancelled) {
            case .unchanged:
                redraw(edit)
            case .save(let value):
                guard let save = parent.cellEditing?.save else { redraw(edit); return }
                tf.stringValue = value
                Task { @MainActor [weak self] in
                    guard let failure = await save(edit.originalRow, edit.column, value), let self else { return }
                    self.redraw(edit)
                    self.reportFailedEdit(edit, attempted: value, message: failure)
                }
            }
        }

        private func redraw(_ edit: InlineSession) {
            guard let table, edit.displayRow < table.numberOfRows else { return }
            table.reloadData(forRowIndexes: IndexSet(integer: edit.displayRow),
                             columnIndexes: IndexSet(integer: edit.tableColumn))
        }

        /// A save the server refused: its message, and the choice to fix the value or drop it.
        private func reportFailedEdit(_ edit: InlineSession, attempted: String, message: String) {
            guard let window = table?.window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save \(result.columns[safe: edit.column] ?? "the value")"
            alert.informativeText = message
            alert.addButton(withTitle: "Edit Again")
            alert.addButton(withTitle: "Discard")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                self.beginInlineEdit(row: edit.displayRow, col: edit.tableColumn, colIdx: edit.column, text: attempted)
            }
        }

        // MARK: Copy / context menu (called from the table subclass)

        func copySelectedRows() {
            guard let table else { return }
            let sel = table.selectedRowIndexes.sorted()
            let header = result.columns.joined(separator: "\t")
            let body = sel.map { r -> String in rowTabbed(displayOrder[safe: r] ?? r) }.joined(separator: "\n")
            setClipboard(header + "\n" + body)
        }

        func contextMenu(clickedRow: Int, clickedColumn: Int) -> NSMenu {
            let menu = NSMenu()
            guard let table else { return menu }
            let sel = table.selectedRowIndexes
            if sel.count > 1 {
                menu.addItem(withTitleAction: "Copy \(sel.count) Selected Rows") { [weak self] in self?.copySelectedRows() }
                menu.addItem(.separator())
            }
            let colIdx = clickedColumn > 0 && clickedColumn <= result.columns.count ? clickedColumn - 1 : lastClickedColumn
            let originalRow = displayOrder[safe: clickedRow] ?? clickedRow
            menu.addItem(withTitleAction: "Copy Cell Value") { [weak self] in
                guard let self else { return }
                let isNull = self.result.isNull(originalRow, colIdx)
                self.setClipboard(isNull ? "" : self.result.cells.value(originalRow, colIdx))
            }
            menu.addItem(.separator())
            menu.addItem(withTitleAction: "Copy Row") { [weak self] in self?.setClipboard(self?.rowTabbed(originalRow) ?? "") }
            menu.addItem(withTitleAction: "Copy Row with Column Names") { [weak self] in
                guard let self else { return }
                self.setClipboard(self.result.columns.joined(separator: "\t") + "\n" + self.rowTabbed(originalRow))
            }
            menu.addItem(.separator())
            menu.addItem(withTitleAction: "Copy as SQL INSERT") { [weak self] in
                guard let self else { return }
                let row = self.result.row(originalRow)
                guard !row.isEmpty else { return }
                self.setClipboard(SQLBuilder.insertStatement(table: self.parent.tableName ?? "table_name",
                                                             columns: self.result.columns, row: row))
            }
            if let editing = parent.cellEditing, editing.reason(colIdx) == nil {
                menu.addItem(.separator())
                menu.addItem(withTitleAction: "Set to NULL") {
                    Task {
                        // A refused or failed write is shown, never swallowed.
                        if let failure = await editing.save(originalRow, colIdx, nil) {
                            let alert = NSAlert()
                            alert.messageText = "The cell was not changed"
                            alert.informativeText = failure
                            alert.runModal()
                        }
                    }
                }
            }
            return menu
        }

        func selectAllRows() {
            guard let table else { return }
            table.selectRowIndexes(IndexSet(0..<result.rowCount), byExtendingSelection: false)
        }

        private func rowTabbed(_ originalRow: Int) -> String {
            result.row(originalRow).enumerated().map { i, v in
                result.isNull(originalRow, i) ? "" : v
            }.joined(separator: "\t")
        }

        private func setClipboard(_ s: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
}

// MARK: - Cell view

final class DataCellView: NSTableCellView {
    private var isNull = false
    private var numeric = false
    /// True while the cell's text field is the in-cell editor.
    private(set) var isEditingInline = false

    static func make() -> DataCellView {
        let cell = DataCellView()
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.usesSingleLineMode = true
        tf.drawsBackground = false
        tf.isBordered = false
        tf.isEditable = false
        tf.focusRingType = .none
        // Frame-based, not Auto Layout: a constraint solve per cell made rebuilding
        // the ~500 visible cells the dominant cost of every table reload.
        tf.autoresizingMask = [.width]
        cell.addSubview(tf)
        cell.textField = tf
        return cell
    }

    /// Makes the text field the cell's editor. The double-clicked row is selected, and a
    /// selected row draws white text; the editor draws its own light background, so it
    /// takes the normal text colour. Before, typed text was white on white.
    func beginInlineEdit(text: String, placeholder: String?, font: NSFont) {
        guard let tf = textField else { return }
        isEditingInline = true
        tf.font = font                     // a NULL cell's italics go
        tf.stringValue = text
        tf.placeholderString = placeholder
        tf.isEditable = true
        tf.isSelectable = true
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        tf.textColor = .textColor
    }

    func endInlineEdit() {
        guard let tf = textField else { return }
        isEditingInline = false
        tf.isEditable = false
        tf.isSelectable = false
        tf.drawsBackground = false
        tf.placeholderString = nil
        applyColor()
    }

    /// Text inset by the cell padding and centered vertically — the layout the
    /// constraints used to express, done with one frame assignment.
    override func layout() {
        super.layout()
        guard let tf = textField else { return }
        let h = tf.intrinsicContentSize.height
        let pad = Theme.cellPaddingH
        tf.frame = NSRect(x: pad, y: ((bounds.height - h) / 2).rounded(),
                          width: max(0, bounds.width - 2 * pad), height: h)
    }

    func configure(value: String, isNull: Bool, numeric: Bool, font: NSFont) {
        self.isNull = isNull
        self.numeric = numeric
        guard let tf = textField else { return }
        tf.font = font
        tf.stringValue = value
        tf.alignment = numeric ? .right : .left
        tf.isEditable = false      // editing is turned on by a double-click (beginInlineEdit)
        tf.isSelectable = false
        tf.drawsBackground = false
        tf.placeholderString = nil
        isEditingInline = false
        applyColor()
    }

    func configureRowNumber(_ n: Int, font: NSFont) {
        isNull = false; numeric = false
        guard let tf = textField else { return }
        tf.font = Theme.dataNSFont(11)
        tf.stringValue = "\(n)"
        tf.alignment = .right
        tf.isEditable = false; tf.isSelectable = false
        tf.textColor = .tertiaryLabelColor
    }

    private func applyColor() {
        if isEditingInline { textField?.textColor = .textColor; return }
        textField?.textColor = (backgroundStyle == .emphasized) ? .white
                             : (isNull ? .tertiaryLabelColor : .labelColor)
        if isNull { textField?.font = NSFontManager.shared.convert(textField!.font!, toHaveTrait: .italicFontMask) }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColor() }
    }
}

// MARK: - Header cell (aligns the column name with the data below it)

/// The data cell's text sits `Theme.cellPaddingH` from the column's left edge, but
/// NSTableHeaderCell's built-in inset is smaller, so column names looked shifted left
/// of their values. This nudges the title right to line up. The sort indicator still
/// draws at the right edge as usual.
private final class PaddedHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // NSTableHeaderCell already insets the title by ~2pt; add the rest to reach cellPaddingH.
        let inset = max(0, Theme.cellPaddingH - 2)
        let f = NSRect(x: cellFrame.minX + inset, y: cellFrame.minY,
                       width: max(0, cellFrame.width - inset), height: cellFrame.height)
        super.drawInterior(withFrame: f, in: controlView)
    }
}

// MARK: - Table subclass (copy, select-all, context menu)

private final class ResultsNSTableView: NSTableView {
    weak var coordinator: _ResultsTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdOrCtrl: NSEvent.ModifierFlags = mods == .command || mods == .control ? mods : []
        if !cmdOrCtrl.isEmpty, event.charactersIgnoringModifiers == "c", !selectedRowIndexes.isEmpty {
            coordinator?.copySelectedRows(); return
        }
        if !cmdOrCtrl.isEmpty, event.charactersIgnoringModifiers == "a" {
            coordinator?.selectAllRows(); return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let r = row(at: point), c = column(at: point)
        if r >= 0, !selectedRowIndexes.contains(r) {
            selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        }
        return coordinator?.contextMenu(clickedRow: r, clickedColumn: c)
    }
}

private extension NSMenu {
    func addItem(withTitleAction title: String, _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        let target = ClosureMenuItem(action)
        item.target = target
        item.representedObject = target      // retain the target
        addItem(item)
    }
}

private final class ClosureMenuItem: NSObject {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func fire() { closure() }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
