//
//  TableNameSheet.swift
//  SequelBridge
//
//  Rename Table… and Duplicate Table… from a table's context menu, as in Sequel Ace: the
//  new name, and for a copy whether its rows come along.
//

import SwiftUI

struct TableNameRequest: Identifiable {
    enum Action { case rename, duplicate }
    let id = UUID()
    let table: TableInfo
    let conn: Connection
    let action: Action
}

struct TableNameSheet: View {
    let request: TableNameRequest
    let onDone: (_ name: String, _ withRows: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var withRows = true

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isRename: Bool { request.action == .rename }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRename ? "Rename “\(request.table.name)”" : "Duplicate “\(request.table.name)”")
                .font(.headline)
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .accessibilityIdentifier("tableName.field")
            if !isRename {
                Toggle("Copy its rows too", isOn: $withRows)
                    .accessibilityIdentifier("tableName.withRows")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isRename ? "Rename" : "Duplicate") {
                    onDone(trimmed, withRows)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || trimmed == request.table.name)
                .accessibilityIdentifier("tableName.confirm")
            }
        }
        .padding(20)
        .onAppear { name = isRename ? request.table.name : "\(request.table.name)_copy" }
    }
}

/// Import SQL file…: how far it has got, with Stop.
struct ImportProgress: Identifiable {
    let id = UUID()
    let file: String
    var done: Int
    let total: Int
}

struct ImportProgressSheet: View {
    let progress: ImportProgress
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Importing \(progress.file)").font(.headline)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .frame(width: 320)
            Text("Statement \(progress.done.formatted()) of \(progress.total.formatted())")
                .font(.caption).foregroundColor(.secondary).monospacedDigit()
            HStack {
                Spacer()
                Button("Stop", action: onStop).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .interactiveDismissDisabled()
    }
}
