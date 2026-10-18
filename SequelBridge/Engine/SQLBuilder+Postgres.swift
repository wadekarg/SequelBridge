//
//  SQLBuilder+Postgres.swift
//  SequelBridge
//
//  PostgreSQL DDL. The shapes differ enough from MySQL that sharing one code path
//  would obscure both:
//
//  • One MySQL MODIFY COLUMN becomes up to three statements — ALTER COLUMN TYPE,
//    SET/DROP NOT NULL, SET/DROP DEFAULT — because Postgres changes one facet of a
//    column at a time.
//  • Renaming is RENAME COLUMN, not CHANGE.
//  • Indexes are CREATE INDEX / DROP INDEX statements in their own right, not
//    clauses of ALTER TABLE.
//  • There is no ENGINE or CHARSET, and identity is SERIAL rather than
//    AUTO_INCREMENT.
//

import Foundation

nonisolated extension SQLBuilder {

    /// `"schema"."table"` — Postgres quotes identifiers the way DuckDB does.
    static func pgTable(schema: String, table: String) -> String {
        "\(duckIdent(schema)).\(duckIdent(table))"
    }

    /// Maps the type as written in the UI onto something Postgres accepts.
    static func pgType(_ raw: String) -> String {
        let upper = raw.uppercased()
        let base = upper.split(separator: "(").first.map(String.init) ?? upper
        let suffix = upper.contains("(") ? String(upper[upper.firstIndex(of: "(")!...]) : ""
        switch base.trimmingCharacters(in: .whitespaces) {
        case "INT", "INTEGER", "MEDIUMINT":  return "INTEGER"
        case "TINYINT", "SMALLINT":          return "SMALLINT"
        case "BIGINT":                       return "BIGINT"
        case "DOUBLE":                       return "DOUBLE PRECISION"
        case "FLOAT", "REAL":                return "REAL"
        case "DECIMAL", "NUMERIC":           return "NUMERIC\(suffix)"
        case "VARCHAR", "CHARACTER VARYING": return "VARCHAR\(suffix)"
        case "CHAR", "CHARACTER":            return "CHAR\(suffix)"
        case "TEXT", "MEDIUMTEXT", "LONGTEXT", "TINYTEXT": return "TEXT"
        case "DATETIME", "TIMESTAMP":        return "TIMESTAMP"
        case "DATE":                         return "DATE"
        case "TIME":                         return "TIME"
        case "BLOB", "LONGBLOB", "MEDIUMBLOB", "VARBINARY", "BINARY": return "BYTEA"
        case "BOOL", "BOOLEAN":              return "BOOLEAN"
        case "JSON":                         return "JSONB"
        case "UUID":                         return "UUID"
        default:                             return upper
        }
    }

    private static func pgDefaultClause(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let upper = value.uppercased()
        if upper == "NULL" { return nil }
        if upper.hasPrefix("CURRENT_") || upper.hasSuffix(")") { return value }
        if Int(value) != nil || Double(value) != nil { return value }
        return literal(value)
    }

    // MARK: - CREATE TABLE

    static func pgCreateTable(schema: String, table: String, columns: [NewColumnDef]) -> String {
        var defs: [String] = []
        var pk: [String] = []
        for col in columns {
            var def = "  \(duckIdent(col.name)) "
            // SERIAL is Postgres's whole answer to AUTO_INCREMENT: it implies the
            // type, the sequence and the default all at once.
            if col.autoIncrement {
                def += pgType(col.baseType) == "BIGINT" ? "BIGSERIAL" : "SERIAL"
            } else {
                def += pgType(col.fullType)
            }
            if !col.nullable { def += " NOT NULL" }
            if !col.autoIncrement, let d = pgDefaultClause(col.defaultValue) { def += " DEFAULT \(d)" }
            defs.append(def)
            if col.isPrimaryKey { pk.append(duckIdent(col.name)) }
        }
        if !pk.isEmpty { defs.append("  PRIMARY KEY (\(pk.joined(separator: ", ")))") }
        return "CREATE TABLE \(pgTable(schema: schema, table: table)) (\n"
            + defs.joined(separator: ",\n") + "\n)"
    }

    // MARK: - Foreign keys

    static func pgAddForeignKey(schema: String, table: String, name: String, column: String,
                                referencedTable: String, referencedColumn: String,
                                onDelete: String, onUpdate: String) -> String {
        "ALTER TABLE \(pgTable(schema: schema, table: table)) "
        + "ADD CONSTRAINT \(duckIdent(name)) FOREIGN KEY (\(duckIdent(column))) "
        + "REFERENCES \(pgTable(schema: schema, table: referencedTable)) (\(duckIdent(referencedColumn))) "
        + "ON DELETE \(onDelete) ON UPDATE \(onUpdate)"
    }

    /// Postgres has no DROP FOREIGN KEY; a foreign key is just a named constraint.
    static func pgDropForeignKey(schema: String, table: String, name: String) -> String {
        "ALTER TABLE \(pgTable(schema: schema, table: table)) DROP CONSTRAINT \(duckIdent(name))"
    }

    // MARK: - ALTER

    static func pgAlterStatements(schema: String, table: String,
                                  columnEdits: [ColumnEdit],
                                  originalColumns: [ColumnInfo],
                                  deletedColumnNames: Set<String>,
                                  indexEdits: [IndexEdit],
                                  deletedIndexNames: Set<String>) -> [String] {
        let tbl = pgTable(schema: schema, table: table)
        var stmts: [String] = []

        for name in deletedColumnNames.sorted() {
            stmts.append("ALTER TABLE \(tbl) DROP COLUMN \(duckIdent(name))")
        }

        for edit in columnEdits where !deletedColumnNames.contains(edit.originalName ?? "") {
            if edit.isNew {
                var def = "ALTER TABLE \(tbl) ADD COLUMN \(duckIdent(edit.name)) \(pgType(edit.fullType))"
                if !edit.nullable { def += " NOT NULL" }
                if let d = pgDefaultClause(edit.defaultValue) { def += " DEFAULT \(d)" }
                stmts.append(def)
                continue
            }
            guard let orig = originalColumns.first(where: { $0.name == edit.originalName }),
                  edit.hasChanges(from: orig) else { continue }

            let origName = edit.originalName ?? edit.name
            // Rename first, so the statements that follow can use the new name.
            if edit.name != origName {
                stmts.append("ALTER TABLE \(tbl) RENAME COLUMN \(duckIdent(origName)) TO \(duckIdent(edit.name))")
            }
            let col = duckIdent(edit.name)
            let newType = pgType(edit.fullType)
            if newType != pgType(orig.dataType) {
                // USING makes the cast explicit; without it Postgres refuses any
                // conversion it does not consider automatic.
                stmts.append("ALTER TABLE \(tbl) ALTER COLUMN \(col) TYPE \(newType) USING \(col)::\(newType)")
            }
            if edit.nullable != orig.nullable {
                stmts.append("ALTER TABLE \(tbl) ALTER COLUMN \(col) \(edit.nullable ? "DROP NOT NULL" : "SET NOT NULL")")
            }
            if edit.defaultValue != orig.defaultValue {
                if let d = pgDefaultClause(edit.defaultValue) {
                    stmts.append("ALTER TABLE \(tbl) ALTER COLUMN \(col) SET DEFAULT \(d)")
                } else {
                    stmts.append("ALTER TABLE \(tbl) ALTER COLUMN \(col) DROP DEFAULT")
                }
            }
        }

        for name in deletedIndexNames.sorted() {
            if name == "PRIMARY" {
                // The panels call it PRIMARY; on the server it is a constraint named
                // <table>_pkey.
                stmts.append("ALTER TABLE \(tbl) DROP CONSTRAINT \(duckIdent("\(table)_pkey"))")
            } else {
                stmts.append("DROP INDEX \(pgTable(schema: schema, table: name))")
            }
        }

        for edit in indexEdits where edit.isNew {
            let cols = edit.columns.map(duckIdent).joined(separator: ", ")
            switch edit.indexType {
            case "PRIMARY KEY":
                stmts.append("ALTER TABLE \(tbl) ADD PRIMARY KEY (\(cols))")
            case "UNIQUE":
                stmts.append("CREATE UNIQUE INDEX \(duckIdent(edit.name)) ON \(tbl) (\(cols))")
            default:
                stmts.append("CREATE INDEX \(duckIdent(edit.name)) ON \(tbl) (\(cols))")
            }
        }

        return stmts
    }
}
