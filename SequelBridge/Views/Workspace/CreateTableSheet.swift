//  CreateTableSheet.swift — Create a new MySQL table from scratch

import SwiftUI

// MARK: - Column definition for new table

nonisolated struct NewColumnDef: Identifiable {
    var id = UUID()
    var name: String        = "column_name"
    var baseType: String    = "VARCHAR"
    var length: String      = "255"
    var nullable: Bool      = true
    var autoIncrement: Bool = false
    var isPrimaryKey: Bool  = false
    var defaultValue: String = ""

    var fullType: String {
        length.isEmpty ? baseType : "\(baseType)(\(length))"
    }
}

// MARK: - Sheet

struct CreateTableSheet: View {
    @Binding var isPresented: Bool
    let conn: Connection
    let database: String
    let onCreated: () -> Void

    @EnvironmentObject private var manager: ConnectionManager

    @State private var tableName   = ""
    @State private var engine      = "InnoDB"
    @State private var charset     = "utf8mb4"
    @State private var columns: [NewColumnDef] = [
        { var c = NewColumnDef(); c.name = "id"; c.baseType = "INT"; c.length = ""; c.nullable = false; c.autoIncrement = true; c.isPrimaryKey = true; return c }()
    ]
    @State private var error: String?
    @State private var isCreating  = false
    @State private var showPreview = false

    private let engines  = ["InnoDB", "MyISAM", "Memory", "CSV", "ARCHIVE"]
    private let charsets = ["utf8mb4", "utf8", "latin1", "ascii", "utf16"]
    private let types    = ["INT","BIGINT","SMALLINT","TINYINT","DECIMAL","FLOAT","DOUBLE",
                            "VARCHAR","CHAR","TEXT","MEDIUMTEXT","LONGTEXT",
                            "DATE","DATETIME","TIMESTAMP","TIME","YEAR",
                            "BOOLEAN","JSON","BLOB","ENUM"]

    private var isValid: Bool {
        !tableName.trimmingCharacters(in: .whitespaces).isEmpty && !columns.isEmpty &&
        columns.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Create Table").font(.title2).bold()
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.title3)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Table settings
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Table Settings", systemImage: "tablecells").font(.headline)

                        HStack(spacing: 12) {
                            field("Table Name") {
                                TextField("table_name", text: $tableName)
                                    .textFieldStyle(.roundedBorder)
                            }
                            field("Engine") {
                                Picker("", selection: $engine) {
                                    ForEach(engines, id: \.self) { Text($0).tag($0) }
                                }.labelsHidden().frame(width: 110)
                            }
                            field("Charset") {
                                Picker("", selection: $charset) {
                                    ForEach(charsets, id: \.self) { Text($0).tag($0) }
                                }.labelsHidden().frame(width: 110)
                            }
                        }
                    }

                    Divider()

                    // Columns
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Columns", systemImage: "list.bullet").font(.headline)
                            Spacer()
                            Button { columns.append(NewColumnDef()) } label: {
                                Label("Add Column", systemImage: "plus")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }

                        // Column header
                        HStack(spacing: 0) {
                            colHdr("Name",      180)
                            colHdr("Type",      110)
                            colHdr("Length",     70)
                            colHdr("Default",    90)
                            colHdr("PK",         36)
                            colHdr("AI",         36)
                            colHdr("NULL",       44)
                            colHdr("",           28)
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)

                        Divider()

                        ForEach($columns) { $col in
                            columnRow(col: $col)
                            Divider().opacity(0.4)
                        }
                    }

                    // SQL Preview
                    DisclosureGroup("SQL Preview", isExpanded: $showPreview) {
                        Text(generateSQL())
                            .font(Theme.mono(11))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                    }

                    if let err = error {
                        Label(err, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red).font(.caption)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button(isCreating ? "Creating…" : "Create Table") {
                    Task { await createTable() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isCreating)
            }
            .padding(20)
        }
        .frame(width: 680, height: 580)
    }

    // MARK: - Column row

    private func columnRow(col: Binding<NewColumnDef>) -> some View {
        HStack(spacing: 0) {
            TextField("name", text: col.name)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                .frame(width: 176)
                .padding(.trailing, 4)

            Picker("", selection: col.baseType) {
                ForEach(types, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 106).padding(.trailing, 4)

            TextField("255", text: col.length)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                .frame(width: 66).padding(.trailing, 4)

            TextField("", text: col.defaultValue)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                .frame(width: 86).padding(.trailing, 4)

            Toggle("", isOn: col.isPrimaryKey)
                .labelsHidden().frame(width: 32).padding(.trailing, 4)
                .onChange(of: col.isPrimaryKey.wrappedValue) { _, isPK in
                    if isPK { col.nullable.wrappedValue = false }
                }

            Toggle("", isOn: col.autoIncrement)
                .labelsHidden().frame(width: 32).padding(.trailing, 4)

            Toggle("", isOn: col.nullable)
                .labelsHidden().frame(width: 40).padding(.trailing, 4)

            Button {
                columns.removeAll { $0.id == col.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red.opacity(0.7))
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .disabled(columns.count <= 1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    // MARK: - SQL generation

    private func generateSQL() -> String {
        let name = tableName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "-- Enter a table name above" }
        if conn.engine == .postgres {
            // Postgres has no ENGINE or CHARSET, and identity is SERIAL.
            return SQLBuilder.pgCreateTable(schema: database, table: name, columns: columns)
        }
        return SQLBuilder.createTable(database: database, table: name,
                                      columns: columns, engine: engine, charset: charset)
    }

    // MARK: - Create

    private func createTable() async {
        isCreating = true; error = nil
        let sql = generateSQL()
        do {
            // CREATE TABLE is MySQL DDL — it has to be passed through to the
            // server, not handed to DuckDB's parser.
            try await manager.queryEngine.executeDDL(alias: conn.alias, sql: sql)
            isPresented = false
            onCreated()
        } catch {
            self.error = QueryEngine.extractReason(from: error)
        }
        isCreating = false
    }

    // MARK: - Helpers

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            content()
        }
    }

    private func colHdr(_ label: String, _ width: CGFloat) -> some View {
        Text(label).frame(width: width, alignment: .leading)
    }
}
