//  ConsolePanelView.swift — Query execution log

import SwiftUI
import UniformTypeIdentifiers

struct ConsolePanelView: View {
    @ObservedObject var session: WorkspaceSession
    @State private var copiedId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Console", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Button("Export…") { exportConsole() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .disabled(session.consoleLog.isEmpty)
                    .help("Save all logged queries to a .sql file")
                Button("Clear") { session.consoleLog.removeAll() }
                    .accessibilityIdentifier("console.clear")
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .disabled(session.consoleLog.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if session.consoleLog.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("Queries you run will appear here")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    // Newest first: the most recent query sits at the top, so it's always
                    // visible without scrolling. Only the DISPLAY is reversed — consoleLog
                    // stays chronological so an exported .sql runs in execution order.
                    List(Array(session.consoleLog.reversed())) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2).monospacedDigit().foregroundColor(.secondary)
                                Spacer()
                                if entry.error != nil {
                                    Text("ERROR").font(.caption2.bold()).foregroundColor(.red)
                                } else {
                                    Text(String(format: "%.3fs", entry.duration))
                                        .font(.caption2).monospacedDigit().foregroundColor(.secondary)
                                    if let rows = entry.rowsAffected {
                                        Text(Plural.count(rows, "row"))
                                            .font(.caption2).monospacedDigit().foregroundColor(.secondary)
                                    }
                                }
                                Button { copySQL(entry) } label: {
                                    Image(systemName: copiedId == entry.id ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 11))
                                        .foregroundColor(copiedId == entry.id ? .green : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Copy SQL")
                            }
                            Text(entry.sql)
                                .font(Theme.mono(11))
                                .lineLimit(3)
                                .textSelection(.enabled)
                            if let err = entry.error {
                                Text(err).font(.caption).foregroundColor(.red)
                            }
                        }
                        .padding(.vertical, 3)
                        .contextMenu {
                            Button("Copy SQL") { copySQL(entry) }
                        }
                        .id(entry.id)
                    }
                    .listStyle(.inset)
                    .onChange(of: session.consoleLog.count) { _, _ in
                        // The newest entry is now the first row — keep it in view at the top.
                        if let newest = session.consoleLog.last {
                            proxy.scrollTo(newest.id, anchor: .top)
                        }
                    }
                }
            }
        }
    }

    private func copySQL(_ entry: WorkspaceSession.ConsoleEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.sql, forType: .string)
        withAnimation { copiedId = entry.id }
        let id = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { if copiedId == id { copiedId = nil } }
        }
    }

    private func exportConsole() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "console_history.sql"
        panel.message = "Export all console queries as a .sql file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ConsoleExporter.sqlDump(session.consoleLog).write(to: url, atomically: true, encoding: .utf8)
    }
}
