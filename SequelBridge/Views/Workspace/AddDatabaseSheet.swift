//
//  AddDatabaseSheet.swift
//  SequelBridge
//
//  Add Database… in the database menu, as in Sequel Ace: a name, an encoding and a
//  collation, each starting at the server's default.
//

import SwiftUI

struct AddDatabaseRequest: Identifiable {
    let id = UUID()
    let conn: Connection
}

/// A database Delete Database… is about to drop, awaiting the confirmation.
struct DatabaseToDelete {
    let conn: Connection
    let name: String
}

struct AddDatabaseSheet: View {
    let request: AddDatabaseRequest
    let engine: QueryEngine
    /// Makes the database; returns the server's reason when it refuses.
    let create: (_ name: String, _ charset: String, _ collation: String) async -> String?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var charset = ""        // empty: the server's default
    @State private var collation = ""      // empty: the encoding's default
    @State private var charsets: [String] = []
    @State private var collations: [DatabaseCollation] = []
    @State private var defaults = (charset: "", collation: "")
    @State private var failure: String?
    @State private var creating = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// The collation an empty pick means: the encoding's default, or the server's.
    private var defaultCollation: String {
        charset.isEmpty ? defaults.collation : (DatabaseCollation.offered(collations, charset: charset).first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Database").font(.title2).bold()
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("Name").foregroundColor(.secondary).gridColumnAlignment(.trailing)
                    TextField("new_database", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { add() }
                        .accessibilityIdentifier("addDatabase.name")
                }
                GridRow {
                    Text("Encoding").foregroundColor(.secondary)
                    Picker("Encoding", selection: $charset) {
                        Text(defaults.charset.isEmpty ? "Default" : "Default (\(defaults.charset))").tag("")
                        Divider()
                        ForEach(charsets, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("addDatabase.charset")
                }
                GridRow {
                    Text("Collation").foregroundColor(.secondary)
                    Picker("Collation", selection: $collation) {
                        Text(defaultCollation.isEmpty ? "Default" : "Default (\(defaultCollation))").tag("")
                        Divider()
                        ForEach(DatabaseCollation.offered(collations, charset: charset.isEmpty ? defaults.charset : charset),
                                id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("addDatabase.collation")
                }
            }
            .padding(20)
            if let failure {
                Text(failure)
                    .font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || creating)
                    .accessibilityIdentifier("addDatabase.add")
            }
            .padding(20)
        }
        .frame(width: 440)
        .onChange(of: charset) { _, _ in collation = "" }    // a collation belongs to one encoding
        .task {
            let alias = request.conn.alias
            charsets = (try? await engine.fetchCharsets(alias: alias)) ?? []
            collations = (try? await engine.fetchCollations(alias: alias)) ?? []
            if let found = try? await engine.serverDefaults(alias: alias) { defaults = found }
        }
    }

    private func add() {
        guard !trimmedName.isEmpty, !creating else { return }
        creating = true
        Task {
            failure = await create(trimmedName, charset, collation)
            creating = false
            if failure == nil { dismiss() }
        }
    }
}
