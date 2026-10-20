//
//  QueryEngine+SQLite.swift
//  SequelBridge
//
//  SQLite metadata. SQLite has no queryable catalog of constraints, and DuckDB's
//  views are not a substitute: duckdb_constraints() reports constraint types with
//  NULL column names, and duckdb_indexes() reports is_unique = false even for a
//  UNIQUE index. So types and nullability come from duckdb_columns(), and primary
//  keys, indexes, foreign keys and triggers are parsed out of the DDL text that
//  sqlite_master stores.
//
//  A SQLite connection is a file, not a server: there is no host, port or
//  credentials, and exactly one schema, always called "main".
//

import Foundation

extension QueryEngine {

    /// Reads sqlite_master directly from the file. sqlite_query() does not exist in
    /// this scanner version, so sqlite_scan is the only route to the DDL.
    private func masterRows(_ alias: String) async throws -> [[String]] {
        guard let path = sqlitePath(for: alias) else { return [] }
        let sql = "SELECT type, name, tbl_name, sql FROM sqlite_scan(\(SQLBuilder.literal(path)), 'sqlite_master')"
        return try await metaQueryPublic(sql).rows
    }

    /// The CREATE TABLE statement the file keeps for `table`, as written; empty when none.
    func sqliteCreateStatement(_ alias: String, table: String) async throws -> String {
        let rows = try await masterRows(alias)
        return rows.first { $0.count >= 4 && $0[0] == "table" && $0[1] == table }?[3] ?? ""
    }

    // MARK: - Schemas

    /// SQLite has exactly one schema, and DuckDB exposes it under this name.
    func fetchDatabasesSQLite(alias: String) async throws -> [String] { ["main"] }

    // MARK: - Tables

    func fetchTablesSQLite(alias: String, database: String) async throws -> [TableInfo] {
        let rows = try await masterRows(alias)
        return rows.compactMap { row -> TableInfo? in
            guard row.count >= 2 else { return nil }
            let kind = row[0]
            guard kind == "table" || kind == "view" else { return nil }
            let name = row[1]
            // Internal bookkeeping table behind AUTOINCREMENT; not the user's data.
            guard name != "sqlite_sequence", !name.hasPrefix("sqlite_autoindex") else { return nil }
            return TableInfo(id: "\(alias).\(name)", name: name,
                             type: kind == "view" ? .view : .table, alias: alias)
        }
    }

    // MARK: - Columns

    func fetchColumnsSQLite(alias: String, database: String, table: String) async throws -> [ColumnInfo] {
        // Declared types and defaults come from the DDL, which preserves what the
        // author wrote (TEXT, REAL) rather than DuckDB's normalisation of it.
        let ddl = try await sqliteCreateStatement(alias, table: table)
        let parsed = SQLiteSchema.parseColumns(fromCreateTable: ddl)
        guard !parsed.isEmpty else { return [] }

        // AUTOINCREMENT is SQLite's identity marker and only ever applies to the
        // INTEGER PRIMARY KEY.
        let autoinc = ddl.uppercased().contains("AUTOINCREMENT")

        return parsed.map { c in
            ColumnInfo(
                id: "\(table).\(c.name)",
                name: c.name,
                dataType: c.type.isEmpty ? "BLOB" : c.type,   // SQLite allows a typeless column
                nullable: !(c.notNull || c.isPrimaryKey),
                keyType: c.isPrimaryKey ? "PRI" : "",
                defaultValue: c.defaultValue,
                extra: (c.isPrimaryKey && autoinc) ? "auto_increment" : "",
                encoding: "",
                collation: "",
                comment: ""
            )
        }
    }

    // MARK: - Indexes

    func fetchIndexesSQLite(alias: String, database: String, table: String) async throws -> [IndexInfo] {
        let rows = try await masterRows(alias)
        var out: [IndexInfo] = []

        // The primary key is not an index in sqlite_master; it lives in the table DDL.
        let ddl = rows.first { $0.count >= 4 && $0[0] == "table" && $0[1] == table }?[3] ?? ""
        let pkCols = SQLiteSchema.parseColumns(fromCreateTable: ddl).filter(\.isPrimaryKey).map(\.name)
        if !pkCols.isEmpty {
            out.append(IndexInfo(id: "\(table).PRIMARY", name: "PRIMARY",
                                 columns: pkCols, unique: true, indexType: "BTREE"))
        }

        for row in rows where row.count >= 4 && row[0] == "index" && row[2] == table {
            // An implicit index backing a UNIQUE column has no DDL text.
            guard !row[3].isEmpty, row[3] != "NULL",
                  let idx = SQLiteSchema.parseIndex(fromCreateIndex: row[3]) else { continue }
            out.append(IndexInfo(id: "\(table).\(idx.name)", name: idx.name,
                                 columns: idx.columns, unique: idx.unique, indexType: "BTREE"))
        }
        return out
    }

    // MARK: - Foreign keys

    func fetchRelationsSQLite(alias: String, database: String, table: String) async throws -> [[String]] {
        SQLiteSchema.parseForeignKeys(fromCreateTable: try await sqliteCreateStatement(alias, table: table))
    }

    // MARK: - Triggers

    func fetchTriggersSQLite(alias: String, database: String, table: String) async throws -> [[String]] {
        let rows = try await masterRows(alias)
        return rows.compactMap { row -> [String]? in
            guard row.count >= 4, row[0] == "trigger", row[2] == table else { return nil }
            let sql = row[3]
            let upper = sql.uppercased()
            let event = ["INSERT", "UPDATE", "DELETE"].first { upper.contains($0) } ?? ""
            let timing = upper.contains("INSTEAD OF") ? "INSTEAD OF"
                       : upper.contains("AFTER") ? "AFTER" : "BEFORE"
            // [name, event, table, timing, statement, definer]
            return [row[1], event, table, timing, sql, ""]
        }
    }

    // MARK: - Table meta

    func fetchTableMetaSQLite(alias: String, database: String, table: String) async throws -> [String] {
        var rowCount = ""
        if let r = try? await sidebarQueryPublic(
            "SELECT COUNT(*) FROM \(SQLBuilder.duckIdent(alias)).\(SQLBuilder.duckIdent(table))"),
           let n = r.rows.first?.first {
            rowCount = n
        }
        var meta = Array(repeating: "", count: 15)
        meta[0] = "SQLite"        // engine
        meta[6] = rowCount
        return meta
    }
}
