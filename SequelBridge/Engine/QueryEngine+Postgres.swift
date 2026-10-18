//
//  QueryEngine+Postgres.swift
//  SequelBridge
//
//  PostgreSQL metadata. Every statement here was verified against 16.15 — see
//  docs/superpowers/specs/2026-08-27-postgres-engine.md.
//
//  Two structural differences from MySQL run through all of it:
//
//  • What the app calls a "database" is a Postgres *schema*. One ATTACH binds one
//    Postgres database (from the DSN's dbname), and every schema inside it is
//    reachable as the middle part of `alias.schema.table` — which is exactly the
//    slot the app already uses for a MySQL database.
//
//  • Absent metadata is a real SQL NULL here, not the string "NULL", so the
//    coalescing happens in SQL rather than in Swift.
//

import Foundation

extension QueryEngine {

    /// Wraps a catalog query for postgres_scanner. Unlike mysql_query(), this is
    /// safe for any statement that returns rows.
    private func pgQuery(_ alias: String, _ sql: String) -> String {
        "SELECT * FROM postgres_query(\(SQLBuilder.literal(alias)), \(SQLBuilder.literal(sql)))"
    }

    // MARK: - Schemas (presented as "databases")

    func fetchDatabasesPostgres(alias: String) async throws -> [String] {
        let sql = """
            SELECT nspname FROM pg_namespace
            WHERE nspname NOT IN ('pg_catalog','information_schema')
              AND nspname NOT LIKE 'pg_toast%' AND nspname NOT LIKE 'pg_temp%'
            ORDER BY nspname
            """
        let r = try await schemaQuery(pgQuery(alias, sql))
        return r.rows.compactMap { $0.first }.filter { $0 != "NULL" }
    }

    // MARK: - Tables

    func fetchTablesPostgres(alias: String, database schema: String) async throws -> [TableInfo] {
        // Escape apostrophes ONCE here (for the Postgres parse of this inner SQL).
        // pgQuery wraps this whole string in SQLBuilder.literal(), which doubles
        // quotes a second time for the DuckDB parse — so `''` here is correct, not `''''`.
        let s = schema.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT table_name AS t_name, table_type AS t_type FROM information_schema.tables
            WHERE table_schema = '\(s)'
            ORDER BY table_name
            """
        let r = try await schemaQuery(pgQuery(alias, sql))
        return r.rows.compactMap { row -> TableInfo? in
            guard let name = row.first, name != "NULL" else { return nil }
            let kind = row.count > 1 && row[1] == "VIEW" ? TableType.view : .table
            return TableInfo(id: "\(alias).\(name)", name: name, type: kind, alias: alias)
        }
    }

    // MARK: - Columns

    func fetchColumnsPostgres(alias: String, database schema: String, table: String) async throws -> [ColumnInfo] {
        let s = schema.replacingOccurrences(of: "'", with: "''")
        let t = table.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT c.column_name,
                   CASE
                     WHEN c.character_maximum_length IS NOT NULL
                       THEN c.data_type || '(' || c.character_maximum_length || ')'
                     WHEN c.data_type = 'numeric' AND c.numeric_precision IS NOT NULL
                       THEN c.data_type || '(' || c.numeric_precision || ',' || c.numeric_scale || ')'
                     ELSE c.data_type
                   END AS full_type,
                   c.is_nullable,
                   COALESCE(pk.kind, '') AS key_type,
                   COALESCE(c.column_default, '') AS col_default,
                   COALESCE(c.collation_name, '') AS collation,
                   COALESCE(pgd.description, '') AS comment
            FROM information_schema.columns c
            LEFT JOIN (
              SELECT kcu.column_name,
                     CASE WHEN tc.constraint_type = 'PRIMARY KEY' THEN 'PRI' ELSE 'UNI' END AS kind
              FROM information_schema.table_constraints tc
              JOIN information_schema.key_column_usage kcu
                ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
              WHERE tc.table_schema = '{S}' AND tc.table_name = '{T}'
                AND tc.constraint_type IN ('PRIMARY KEY','UNIQUE')
            ) pk ON pk.column_name = c.column_name
            LEFT JOIN pg_catalog.pg_statio_all_tables st
              ON st.schemaname = c.table_schema AND st.relname = c.table_name
            LEFT JOIN pg_catalog.pg_description pgd
              ON pgd.objoid = st.relid AND pgd.objsubid = c.ordinal_position
            WHERE c.table_schema = '{S}' AND c.table_name = '{T}'
            ORDER BY c.ordinal_position
            """
            .replacingOccurrences(of: "{S}", with: s)
            .replacingOccurrences(of: "{T}", with: t)

        let r = try await metaQueryPublic(pgQuery(alias, sql))
        return r.rows.compactMap { row -> ColumnInfo? in
            guard let name = row.first, name != "NULL" else { return nil }
            func f(_ i: Int) -> String {
                guard i < row.count else { return "" }
                return row[i] == "NULL" ? "" : row[i]
            }
            let rawDefault = f(4)
            // A serial column's identity lives in its default as nextval(...); MySQL
            // reports the same thing in Extra, which is where the panels look.
            let isSerial = rawDefault.hasPrefix("nextval(")
            return ColumnInfo(
                id: "\(table).\(name)",
                name: name,
                dataType: f(1),
                nullable: f(2).uppercased() != "NO",
                keyType: f(3),
                defaultValue: isSerial ? "" : rawDefault,
                extra: isSerial ? "auto_increment" : "",
                encoding: "",
                collation: f(5),
                comment: f(6)
            )
        }
    }

    // MARK: - Indexes

    func fetchIndexesPostgres(alias: String, database schema: String, table: String) async throws -> [IndexInfo] {
        let s = schema.replacingOccurrences(of: "'", with: "''")
        let t = table.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT i.relname, ix.indisunique, ix.indisprimary, a.attname, k.ord, am.amname
            FROM pg_index ix
            JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_class c ON c.oid = ix.indrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_am am ON am.oid = i.relam
            JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
            JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
            WHERE n.nspname = '\(s)' AND c.relname = '\(t)'
            ORDER BY i.relname, k.ord
            """
        let r = try await metaQueryPublic(pgQuery(alias, sql))

        struct Entry { var unique: Bool; var primary: Bool; var type: String; var cols: [String] }
        var order: [String] = []
        var byName: [String: Entry] = [:]
        for row in r.rows where row.count >= 6 {
            let name = row[0]
            if byName[name] == nil {
                byName[name] = Entry(unique: row[1] == "true" || row[1] == "1",
                                     primary: row[2] == "true" || row[2] == "1",
                                     type: row[5].uppercased(), cols: [])
                order.append(name)
            }
            byName[name]?.cols.append(row[3])
        }
        return order.compactMap { name in
            guard let e = byName[name] else { return nil }
            // Postgres names it "<table>_pkey"; the panels — and the DROP PRIMARY KEY
            // path in SQLBuilder — recognise the MySQL spelling.
            let display = e.primary ? "PRIMARY" : name
            return IndexInfo(id: "\(table).\(display)", name: display,
                             columns: e.cols, unique: e.unique, indexType: e.type)
        }
    }

    // MARK: - Foreign keys

    func fetchRelationsPostgres(alias: String, database schema: String, table: String) async throws -> [[String]] {
        let s = schema.replacingOccurrences(of: "'", with: "''")
        let t = table.replacingOccurrences(of: "'", with: "''")
        // pg_constraint exposes the referential actions directly, so unlike MySQL
        // there is no DDL to parse.
        let sql = """
            SELECT con.conname AS fk_name, att.attname AS fk_col,
                   ref_t.relname AS ref_table, ref_att.attname AS ref_col,
                   CASE con.confdeltype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
                        WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
                        WHEN 'd' THEN 'SET DEFAULT' ELSE 'RESTRICT' END AS on_delete,
                   CASE con.confupdtype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
                        WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
                        WHEN 'd' THEN 'SET DEFAULT' ELSE 'RESTRICT' END AS on_update
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_class ref_t ON ref_t.oid = con.confrelid
            JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS ck(attnum, ord) ON true
            JOIN pg_attribute att ON att.attrelid = c.oid AND att.attnum = ck.attnum
            JOIN LATERAL unnest(con.confkey) WITH ORDINALITY AS fk(attnum, ord) ON fk.ord = ck.ord
            JOIN pg_attribute ref_att ON ref_att.attrelid = ref_t.oid AND ref_att.attnum = fk.attnum
            WHERE con.contype = 'f' AND n.nspname = '\(s)' AND c.relname = '\(t)'
            ORDER BY con.conname, ck.ord
            """
        let r = try await metaQueryPublic(pgQuery(alias, sql))
        return r.rows.filter { $0.count >= 6 }
    }

    // MARK: - Triggers

    func fetchTriggersPostgres(alias: String, database schema: String, table: String) async throws -> [[String]] {
        let s = schema.replacingOccurrences(of: "'", with: "''")
        let t = table.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT tg.tgname AS trg_name,
                   CASE WHEN (tg.tgtype & 4) > 0 THEN 'INSERT'
                        WHEN (tg.tgtype & 8) > 0 THEN 'DELETE'
                        WHEN (tg.tgtype & 16) > 0 THEN 'UPDATE' ELSE 'TRUNCATE' END AS trg_event,
                   CASE WHEN (tg.tgtype & 2) > 0 THEN 'BEFORE' ELSE 'AFTER' END AS trg_timing,
                   pg_get_functiondef(tg.tgfoid) AS trg_body,
                   pg_get_userbyid(c.relowner) AS trg_owner
            FROM pg_trigger tg
            JOIN pg_class c ON c.oid = tg.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE NOT tg.tgisinternal AND n.nspname = '\(s)' AND c.relname = '\(t)'
            ORDER BY tg.tgname
            """
        let r = try await metaQueryPublic(pgQuery(alias, sql))
        // Callers expect [name, event, table, timing, statement, definer]
        return r.rows.compactMap { row in
            guard row.count >= 5 else { return nil }
            return [row[0], row[1], table, row[2], row[3], row[4]]
        }
    }

    // MARK: - Table meta

    func fetchTableMetaPostgres(alias: String, database schema: String, table: String) async throws -> [String] {
        let s = schema.replacingOccurrences(of: "'", with: "''")
        let t = table.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT COALESCE(am.amname, '') AS access_method,
                   CASE WHEN c.reltuples >= 0 THEN c.reltuples::bigint
                        ELSE COALESCE(st.n_live_tup, -1) END AS approx_rows,
                   pg_table_size(c.oid) AS data_bytes,
                   pg_indexes_size(c.oid) AS index_bytes,
                   COALESCE(obj_description(c.oid), '') AS tbl_comment,
                   COALESCE(col.dbcollation, '') AS tbl_collation
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_am am ON am.oid = c.relam
            LEFT JOIN pg_stat_all_tables st ON st.relid = c.oid
            LEFT JOIN LATERAL (
              SELECT datcollate AS dbcollation FROM pg_database WHERE datname = current_database()
            ) col ON true
            WHERE n.nspname = '\(s)' AND c.relname = '\(t)'
            """
        guard let r = try? await sidebarQueryPublic(pgQuery(alias, sql)), let row = r.rows.first else {
            return Array(repeating: "", count: 15)
        }
        func f(_ i: Int) -> String {
            guard i < row.count, row[i] != "NULL" else { return "" }
            return row[i]
        }
        // reltuples is -1 until the table has been analyzed; the query then falls back
        // to the stats collector's live-tuple count, which inserts keep current without
        // ANALYZE. -1 only when both are missing — "unknown", not a row count, and it
        // must not reach the UI as "-1 rows" (nor the cross-server planner, which
        // ranks an unknown estimate as the largest side).
        let rows = Int(f(1)).map { $0 < 0 ? "" : String($0) } ?? ""
        return [
            f(0),        // engine → access method (heap)
            "",          // row_format
            "",          // auto_increment
            f(5),        // collation
            "",          // create_options
            f(4),        // comment
            rows,
            "",          // avg_row_length
            f(2),        // data_length → table size (heap+toast, excl. indexes)
            "",          // max_data_length
            f(3),        // index_length → pg_indexes_size
            "",          // data_free
            "", "", "",  // create/update/check time
        ]
    }
}
