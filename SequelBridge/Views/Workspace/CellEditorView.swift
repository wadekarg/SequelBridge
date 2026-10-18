//
//  CellEditorView.swift
//  SequelBridge
//
//  The popup a double-click opens beside a grid cell. It shows the full value; where
//  the cell can be edited (the Content tab, a writable connection, a table with a
//  primary key) Edit turns it into an editor, Save writes it, Cancel leaves it as it
//  was. A failed save keeps the popup open and shows the server's message. A cell that
//  can't be edited says why.
//

import AppKit
import SwiftUI

struct CellEditorView: View {
    @State var state: CellEditorState
    /// Writes the value (nil = NULL). Returns the error message, or nil on success.
    let save: (String?) async -> String?
    let close: () -> Void

    @State private var saving = false
    @State private var error: String? = nil
    @State private var asJSON = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if state.isEditing { editor } else { viewer }
            if let reason = state.readOnlyReason {
                Label(reason, systemImage: "lock")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error)
                    .font(.caption).foregroundColor(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(14)
        .frame(width: 440)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(state.column).font(.headline)
            if !state.columnType.isEmpty {
                Text(state.columnType.lowercased()).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !state.isEditing {
                if state.originalIsNull {
                    Text("NULL").font(.caption.italic()).foregroundColor(.secondary)
                } else {
                    Text("\(state.originalValue.count) characters").font(.caption).foregroundColor(.secondary)
                }
                if looksLikeJSON {
                    Toggle("JSON", isOn: $asJSON).toggleStyle(.button).controlSize(.small)
                }
            }
        }
    }

    private var viewer: some View {
        ScrollView {
            Text(state.originalIsNull ? "NULL" : displayValue)
                .font(Theme.mono(12))
                .foregroundColor(state.originalIsNull ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: 44, maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $state.text)
                .font(Theme.mono(12))
                .focused($editorFocused)
                .frame(height: 120)
                .disabled(state.setNull)
                .opacity(state.setNull ? 0.4 : 1)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            Toggle("NULL", isOn: $state.setNull).controlSize(.small)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.originalIsNull ? "" : state.originalValue, forType: .string)
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            Spacer()
            if saving { ProgressView().controlSize(.small) }
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
            if state.canEdit {
                Button("Edit") {
                    state.isEditing = true
                    editorFocused = true
                }
                .disabled(state.isEditing)
                Button("Save") { Task { await performSave() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canSave || saving)
            }
        }
    }

    private func performSave() async {
        saving = true
        error = nil
        let failure = await save(state.newValue)
        saving = false
        if let failure { error = failure } else { close() }
    }

    private var looksLikeJSON: Bool {
        let t = state.originalValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]"))
    }

    private var displayValue: String {
        guard asJSON,
              let data = state.originalValue.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else { return state.originalValue }
        return str
    }
}
