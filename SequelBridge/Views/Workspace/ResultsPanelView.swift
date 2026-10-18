//
//  ResultsPanelView.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import SwiftUI
import UniformTypeIdentifiers

enum ResultViewMode { case table, chart }

struct ResultsPanelView: View {
    let tab: QueryTab
    /// Runs a cell edit's UPDATE on its connection (sql, alias); the Query tab passes the
    /// engine's guarded write. Without it the grid only shows values.
    var writeCell: ((String, String) async throws -> Void)? = nil
    /// Puts a saved value into the tab's result: the unfiltered result's row, column, value.
    var applyCell: ((Int, Int, String?) -> Void)? = nil
    @State private var filterText = ""
    @State private var viewMode: ResultViewMode = .table

    var body: some View {
        VStack(spacing: 0) {
            if tab.isRunning {
                ProgressView("Running query…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = tab.error {
                errorView(error)
            } else if let result = tab.result {
                let shown = result.filteredByText(filterText)
                if viewMode == .chart {
                    ResultChartView(result: shown)
                } else {
                    ResultsTableView(result: shown, cellEditing: cellEditing(for: shown))
                }
                statusBar(result, shown: shown)
            } else {
                Text("Run a query to see results")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// A double-click opens the value in a popup. Its Edit and Save work where the result
    /// is one table's rows with that table's primary key in it (ResultEditing); the
    /// UPDATE is keyed by the row's key values as shown.
    private func cellEditing(for shown: QueryResult) -> CellEditing? {
        guard let writeCell, let applyCell else { return nil }
        let target = tab.editTarget
        let blocked = tab.editBlockedReason
        return CellEditing(
            style: .popup,
            reason: { col in
                if let blocked { return blocked }
                guard let target else { return ResultEditing.checking }
                return target.reason(forColumn: col)
            },
            revision: tab.editRevision,
            save: { row, col, value in
                guard let target, let sql = target.update(row: row, column: col, value: value, in: shown) else {
                    return blocked ?? ResultEditing.computedColumn
                }
                do { try await writeCell(sql, target.alias) } catch { return QueryEngine.extractReason(from: error) }
                applyCell(shown.sourceRows?[row] ?? row, col, value)
                return nil
            })
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Query Error", systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.headline)
            Text(message)
                .font(Theme.mono(13))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statusBar(_ result: QueryResult, shown: QueryResult) -> some View {
        let filtering = !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 12) {
            HStack(spacing: 4) {
                if tab.isStreaming {
                    // First rows are already shown and scrollable; the rest stream in.
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    Text("Loading \(result.rowCount) rows…")
                        .font(Theme.fontChromeStrong).monospacedDigit()
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "tablecells").font(.caption2).foregroundColor(.secondary)
                    Text(filtering
                         ? "\(shown.rowCount) of \(result.rowCount) rows"
                         : (result.rowCount == 1 ? "1 row" : "\(result.rowCount) rows"))
                        .font(Theme.fontChromeStrong).monospacedDigit()
                        .foregroundColor(.primary)
                }
            }
            if !tab.isStreaming {
                // While rows stream in, the toolbar's counter is the only clock on
                // screen; once the run completes this shows the same total (RunClock).
                Divider().frame(height: 12)
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.caption2).foregroundColor(.secondary)
                    Text(RunClock.statusText(result.executionTime))
                        .font(Theme.fontChrome).monospacedDigit()
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if result.rowCount > 0 {
                // Table / Chart view toggle.
                Picker("", selection: $viewMode) {
                    Image(systemName: "tablecells").tag(ResultViewMode.table)
                    Image(systemName: "chart.bar").tag(ResultViewMode.chart)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Switch between the table and a chart")
                Divider().frame(height: 12)
                // Instant client-side filter over the loaded rows (no re-query).
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.caption2).foregroundColor(.secondary)
                    TextField("Filter rows", text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 120)
                    if filtering {
                        Button { filterText = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                .help("Filter the loaded rows instantly — no re-query")
                Divider().frame(height: 12)
                Menu {
                    Button(action: { exportCSV(shown) }) {
                        Label("Export as CSV", systemImage: "tablecells")
                    }
                    Button(action: { exportJSON(shown) }) {
                        Label("Export as JSON", systemImage: "curlybraces")
                    }
                    Button(action: { exportMarkdown(shown) }) {
                        Label("Export as Markdown", systemImage: "text.alignleft")
                    }
                    Button(action: { exportSQLInserts(shown) }) {
                        Label("Export as SQL (INSERTs)", systemImage: "arrow.down.doc")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Export

    /// Shared save-panel flow for every export format: confirm (if the result was
    /// capped), pick a destination, then run the format-specific `write`.
    private func exportToFile(_ result: QueryResult, type: UTType, defaultName: String,
                              message: String, write: (URL) throws -> Void) {
        guard confirmExport(result) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = defaultName
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try write(url) } catch { presentExportError(error) }
    }

    private func exportCSV(_ result: QueryResult) {
        exportToFile(result, type: .commaSeparatedText, defaultName: "results.csv",
                     message: "Export query results as CSV") { url in
            try ResultExporter.csv(result).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportJSON(_ result: QueryResult) {
        exportToFile(result, type: .json, defaultName: "results.json",
                     message: "Export query results as JSON") { url in
            try ResultExporter.json(result).write(to: url)
        }
    }

    private func exportMarkdown(_ result: QueryResult) {
        exportToFile(result, type: UTType(filenameExtension: "md") ?? .plainText, defaultName: "results.md",
                     message: "Export query results as a Markdown table") { url in
            try ResultExporter.markdown(result).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportSQLInserts(_ result: QueryResult) {
        exportToFile(result, type: UTType(filenameExtension: "sql") ?? .plainText, defaultName: "results.sql",
                     message: "Export query results as SQL INSERT statements") { url in
            // Use the saved file's base name as the target table, so "orders.sql" → INSERT INTO orders.
            let table = url.deletingPathExtension().lastPathComponent
            try ResultExporter.sqlInserts(result, table: table.isEmpty ? "exported_data" : table)
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// When the result was capped for display (isTruncated), the export would
    /// contain only the loaded rows. Tell the user rather than silently writing a
    /// partial file. Returns false if the user cancels.
    private func confirmExport(_ result: QueryResult) -> Bool {
        guard result.isTruncated else { return true }
        let shown = result.rowCount, total = result.totalRowCount
        let alert = NSAlert()
        alert.messageText = "Export limited to \(shown.formatted()) of \(total.formatted()) rows"
        alert.informativeText = "Only the first \(shown.formatted()) rows were loaded for display, so the export will contain those. Add a WHERE/LIMIT or aggregate the query to export a complete result."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Export \(shown.formatted()) Rows")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't write the export file"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}