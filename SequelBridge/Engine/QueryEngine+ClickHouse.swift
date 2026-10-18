//
//  QueryEngine+ClickHouse.swift
//  SequelBridge
//
//  ClickHouse metadata and statements over the native HTTP client. All shapes
//  match what the panels already consume from the other engines. Relations and
//  triggers return empty — ClickHouse has neither in the MySQL sense.
//

import Foundation

extension QueryEngine {

    func clickhouseClient(for alias: String) throws -> ClickHouseClient {
        guard let client = clickhouseClients[alias] else {
            throw SequelBridgeError.attachFailed("No ClickHouse connection named \(alias)")
        }
        return client
    }

    func attachClickHouse(_ c: Connection, password: String) async throws {
        var host = c.host, port = c.port
        switch c.connectionType {
        case .tcpip:
            break
        case .socket:
            throw SequelBridgeError.attachFailed(
                "ClickHouse connects over TCP/IP or an SSH tunnel, not a Unix socket. Edit the connection and pick one of those.")
        case .ssh:
            // The HTTP interface through the tunnel: c.host:c.port as the SSH server sees it.
            host = "127.0.0.1"
            port = try await startTunnel(for: c)
        }
        let client = ClickHouseClient(host: host, port: port,
                                      user: c.username, password: password, useTLS: c.useSSL)
        // Validate now so a bad host or credential fails at connect, not first use.
        do {
            _ = try await client.query("SELECT 1")
        } catch {
            stopTunnel(c.alias)
            throw error
        }
        clickhouseClients[c.alias] = client
        engines[c.alias] = .clickhouse
        // What `ch.table` resolves to when the sidebar hasn't picked a database — the
        // other engines record it the same way (a bridged join once went out as
        // ``.`table` without it).
        setAttachedDatabase(c.database, for: c.alias)
    }

    func clickhouseQuery(alias: String, sql: String) async throws -> QueryResult {
        let client = try clickhouseClient(for: alias)
        let start = Date()
        do {
            let r = try await client.query(sql)
            onStatement?(sql, r.totalRowCount, nil, Date().timeIntervalSince(start))
            return r
        } catch {
            let reason = Self.extractReason(from: error)
            onStatement?(sql, nil, reason, Date().timeIntervalSince(start))
            throw error
        }
    }

    /// Copies (part of) a ClickHouse table into a DuckDB TEMP table so it can take
    /// part in a cross-engine JOIN — ClickHouse is native HTTP and lives outside
    /// DuckDB's catalog. When `keyColumn`/`keyValues` are given, only rows whose key
    /// is in that list are fetched (the inner-join reduction: a row whose key is on
    /// neither side could never join, so dropping it can't change the result);
    /// `extraWhere` is the table's pushed-down filter (see pushdownWhere), applied by
    /// ClickHouse so only the rows the query can use cross the wire. Columns are typed
    /// via SQLBuilder.clickhouseToDuckType so join keys line up. Runs on `lane` so the
    /// TEMP table is on the same connection as the query that follows. Returns the
    /// quoted temp-table name.
    func materializeClickHouse(alias: String, database: String, table: String,
                               keyColumn: String?, keyValues: [String]?, extraWhere: String? = nil,
                               lane: Lane = .user) async throws -> String {
        // 1. Fetch from ClickHouse, reduced to the matching keys when provided.
        //    `toString(key)` normalizes the key to text so a string IN-list matches
        //    whatever the key's real type is (Int, UUID, String, …).
        func chBacktick(_ s: String) -> String { "`\(s.replacingOccurrences(of: "`", with: "\\`"))`" }
        var conds: [String] = []
        if let keyColumn, let keyValues, !keyValues.isEmpty {
            let inList = keyValues
                .map { "'\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'" }
                .joined(separator: ", ")
            conds.append("toString(\(chBacktick(keyColumn))) IN (\(inList))")
        }
        if let extraWhere, !extraWhere.isEmpty { conds.append(extraWhere) }
        var chSQL = "SELECT * FROM \(chBacktick(database)).\(chBacktick(table))"
        if !conds.isEmpty { chSQL += " WHERE " + conds.joined(separator: " AND ") }
        let res = try await clickhouseClient(for: alias).query(chSQL)
        guard !res.columns.isEmpty else {
            throw SequelBridgeError.attachFailed("ClickHouse table \(database).\(table) returned no columns")
        }

        // 2. Create a TEMP table with DuckDB-compatible column types (keyed by index so
        //    a short type row can't misalign the columns).
        let tempName = "__ch_\(alias)_\(table)"
        let tempIdent = SQLBuilder.duckIdent(tempName)
        let colDefs = res.columns.enumerated().map { i, name in
            let chType = i < res.columnTypes.count ? res.columnTypes[i] : "String"
            return "\(SQLBuilder.duckIdent(name)) \(SQLBuilder.clickhouseToDuckType(chType))"
        }.joined(separator: ", ")
        _ = try await query("CREATE OR REPLACE TEMP TABLE \(tempIdent) (\(colDefs))", lane: lane)

        // 3. Insert the rows in batches. Values are string literals; DuckDB casts each
        //    to the column type. The null mask distinguishes a real NULL from "NULL".
        let batchSize = 500
        let rows = res.rows, nullMask = res.nullMask
        var i = 0
        while i < rows.count {
            let end = min(i + batchSize, rows.count)
            var tuples: [String] = []
            tuples.reserveCapacity(end - i)
            for r in i..<end {
                let row = rows[r]
                let mask = r < nullMask.count ? nullMask[r] : []
                let vals = row.enumerated().map { c, v in
                    (c < mask.count && mask[c]) ? "NULL" : SQLBuilder.literal(v)
                }
                tuples.append("(\(vals.joined(separator: ", ")))")
            }
            _ = try await query("INSERT INTO \(tempIdent) VALUES \(tuples.joined(separator: ", "))", lane: lane)
            i = end
        }
        return tempIdent
    }

    /// The DuckDB statement that runs a two-table join with one ClickHouse side,
    /// planned like a cross-server join (see crossJoinPlan) with the ClickHouse side
    /// copied into a TEMP table — the only way DuckDB can see it. When ClickHouse is
    /// the smaller side it is copied whole, its own pushed-down WHERE applied in
    /// ClickHouse, and the other side streams from its server reduced to the copied
    /// keys (or whole, when the server says the keys aren't selective); when it is
    /// the bigger side it is copied reduced to the other side's keys and the other
    /// side comes whole through its passthrough. An ATTACH'd side with no passthrough
    /// (SQLite) stays a scanner ref. Returns the statement — run it with
    /// `pinJoinOrder`, the big side listed first — and the temp table to drop once
    /// the result has streamed. No scanner fallback exists for ClickHouse: an error
    /// surfaces, and the temp is dropped on the way out.
    func clickHouseJoinPlan(_ cj: SQLBuilder.CrossJoin, baseSQL: String, aliases: [String],
                            databaseFor: (String) -> String) async throws -> (sql: String, temp: String) {
        let chIsA = engines[cj.a.server] == .clickhouse
        let ch = chIsA ? cj.a : cj.b, chDB = databaseFor(ch.server)
        let other = chIsA ? cj.b : cj.a, otherDB = databaseFor(other.server)
        let estCH = await tableRowEstimate(alias: ch.server, database: chDB, table: ch.table)
        let estOther = await tableRowEstimate(alias: other.server, database: otherDB, table: other.table)
        let pushed = await pushdownWhere(baseSQL: baseSQL, aliases: aliases, databaseFor: databaseFor)
        func extra(_ side: SQLBuilder.CrossJoin.Side) -> String? {
            pushed[Self.pushdownKey(alias: side.server, table: side.table)]
        }
        func scannerRef(_ side: SQLBuilder.CrossJoin.Side, _ db: String) -> String {
            SQLBuilder.duckTable(alias: side.server, database: db, table: side.table)
        }
        // Both sides can be fetched, so the row estimates alone pick the big side.
        let bigIsA = SQLBuilder.crossJoinBigSide(estA: chIsA ? estCH : estOther, estB: chIsA ? estOther : estCH,
                                                 canA: true, canB: true) ?? false
        let chIsBig = bigIsA == chIsA

        let temp: String
        if chIsBig {
            // The other side's distinct keys bound the copy.
            let keys = try await distinctKeys(alias: other.server, database: otherDB, table: other.table,
                                              column: other.key, where: extra(other))
            let vals = keys.rows.map { $0.first ?? "" }
            let nulls = keys.nullMask.map { $0.first ?? false }
            var keyVals: [String] = []
            for (v, isNull) in zip(vals, nulls) where !isNull { keyVals.append(v) }
            temp = try await materializeClickHouse(alias: ch.server, database: chDB, table: ch.table,
                                                   keyColumn: ch.key, keyValues: keyVals.count <= Self.maxInlineKeys ? keyVals : nil,
                                                   extraWhere: extra(ch))
        } else {
            temp = try await materializeClickHouse(alias: ch.server, database: chDB, table: ch.table,
                                                   keyColumn: nil, keyValues: nil, extraWhere: extra(ch))
        }
        do {
            let bigRef: String, probeRef: String
            if chIsBig {
                bigRef = temp
                probeRef = passthroughTable(alias: other.server, database: otherDB, table: other.table,
                                            extraWhere: extra(other)).map { "(\($0))" } ?? scannerRef(other, otherDB)
            } else {
                probeRef = temp
                var ref: String? = nil
                if canPassthrough(other.server) {
                    let keys = try await query("SELECT DISTINCT \(SQLBuilder.duckIdent(ch.key)) FROM \(temp)")
                    let plan = await keyReductionPlan(keys: keys, alias: other.server, database: otherDB, table: other.table,
                                                      keyColumn: other.key, extraWhere: extra(other), rowEstimate: estOther)
                    switch plan {
                    case .reduce(let keyList):
                        ref = reducedBigSide(alias: other.server, database: otherDB, table: other.table,
                                             keyColumn: other.key, keyList: keyList, extraWhere: extra(other))
                    case .fetchWhole, .tooManyKeys:
                        ref = passthroughTable(alias: other.server, database: otherDB, table: other.table, extraWhere: extra(other))
                    }
                }
                bigRef = ref.map { "(\($0))" } ?? scannerRef(other, otherDB)
            }
            return (SQLBuilder.crossJoinRewrite(baseSQL, join: cj, bigIsA: bigIsA, bigRef: bigRef, probeRef: probeRef), temp)
        } catch {
            await dropTempTable(temp)
            throw error
        }
    }

    /// Drops a bridge TEMP table created by `materializeClickHouse`. Best-effort —
    /// a missed drop self-heals because the name is reused via CREATE OR REPLACE and
    /// TEMP tables vanish when the connection closes.
    func dropTempTable(_ quotedName: String, lane: Lane = .user) async {
        _ = try? await query("DROP TABLE IF EXISTS \(quotedName)", lane: lane)
    }

    /// The views of system.query_log the Server panel offers for ClickHouse.
    enum ClickHouseInsight { case recent, slow, byType }

    /// Query Insights from system.query_log — the ClickHouse answer to a process list,
    /// but historical: recent queries, the slowest queries, and a per-type rollup.
    func clickhouseQueryInsights(alias: String, kind: ClickHouseInsight) async throws -> QueryResult {
        let sql: String
        switch kind {
        case .slow:
            sql = """
            SELECT event_time, query_duration_ms AS duration_ms, read_rows,
                   formatReadableSize(memory_usage) AS memory, left(query, 200) AS query
            FROM system.query_log
            WHERE type = 'QueryFinish' AND event_date >= today() - 1
            ORDER BY query_duration_ms DESC
            LIMIT 200
            """
        case .byType:
            sql = """
            SELECT type,
                   count() AS queries,
                   round(avg(query_duration_ms), 1) AS avg_ms,
                   round(quantile(0.95)(query_duration_ms), 1) AS p95_ms,
                   sum(read_rows) AS rows_read
            FROM system.query_log
            WHERE event_date >= today() - 1
            GROUP BY type
            ORDER BY queries DESC
            """
        case .recent:
            sql = """
            SELECT event_time, query_duration_ms AS duration_ms, read_rows,
                   formatReadableSize(memory_usage) AS memory, type,
                   left(query, 200) AS query, exception
            FROM system.query_log
            WHERE type IN ('QueryFinish', 'ExceptionWhileProcessing', 'ExceptionBeforeStart')
            ORDER BY event_time DESC
            LIMIT 200
            """
        }
        return try await clickhouseQuery(alias: alias, sql: sql)
    }

    func clickhouseExecute(alias: String, sql: String) async throws {
        try ensureWritable(alias)
        let client = try clickhouseClient(for: alias)
        let start = Date()
        do {
            try await client.execute(sql)
            onStatement?(sql, nil, nil, Date().timeIntervalSince(start))
        } catch {
            onStatement?(sql, nil, Self.extractReason(from: error), Date().timeIntervalSince(start))
            throw error
        }
    }

    // MARK: - Metadata

    func fetchDatabasesClickHouse(alias: String) async throws -> [String] {
        let r = try await clickhouseClient(for: alias).query("""
            SELECT name FROM system.databases
            WHERE name NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')
            ORDER BY name
            """)
        return r.rows.compactMap(\.first)
    }

    func fetchTablesClickHouse(alias: String, database: String) async throws -> [TableInfo] {
        let db = SQLBuilder.literal(database)
        let r = try await clickhouseClient(for: alias).query("""
            SELECT name, if(engine LIKE '%View', 'VIEW', 'BASE TABLE') AS kind
            FROM system.tables WHERE database = \(db) ORDER BY name
            """)
        return r.rows.compactMap { row in
            guard let name = row.first else { return nil }
            return TableInfo(id: "\(alias).\(name)", name: name,
                             type: row.count > 1 && row[1] == "VIEW" ? .view : .table,
                             alias: alias)
        }
    }

    func fetchColumnsClickHouse(alias: String, database: String, table: String) async throws -> [ColumnInfo] {
        let r = try await clickhouseClient(for: alias).query("""
            SELECT name, type, is_in_primary_key, default_expression, comment
            FROM system.columns
            WHERE database = \(SQLBuilder.literal(database)) AND table = \(SQLBuilder.literal(table))
            ORDER BY position
            """)
        return r.rows.compactMap { row in
            guard let name = row.first else { return nil }
            func f(_ i: Int) -> String { i < row.count && row[i] != "NULL" ? row[i] : "" }
            let type = f(1)
            return ColumnInfo(
                id: "\(table).\(name)", name: name, dataType: type,
                nullable: type.hasPrefix("Nullable("),
                keyType: f(2) == "1" ? "PRI" : "",
                defaultValue: f(3), extra: "", encoding: "", collation: "",
                comment: f(4)
            )
        }
    }

    func fetchIndexesClickHouse(alias: String, database: String, table: String) async throws -> [IndexInfo] {
        // The ORDER BY / primary key is the one index every MergeTree table has.
        let r = try await clickhouseClient(for: alias).query("""
            SELECT primary_key, sorting_key FROM system.tables
            WHERE database = \(SQLBuilder.literal(database)) AND name = \(SQLBuilder.literal(table))
            """)
        guard let row = r.rows.first else { return [] }
        var out: [IndexInfo] = []
        let pk = row.first.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
        if !pk.isEmpty, pk != [""] {
            out.append(IndexInfo(id: "\(table).PRIMARY", name: "PRIMARY", columns: pk, unique: false, indexType: "MERGETREE"))
        }
        if row.count > 1 {
            let sk = row[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if !sk.isEmpty, sk != pk, sk != [""] {
                out.append(IndexInfo(id: "\(table).sorting", name: "sorting_key", columns: sk, unique: false, indexType: "MERGETREE"))
            }
        }
        return out
    }

    func fetchTableMetaClickHouse(alias: String, database: String, table: String) async throws -> [String] {
        let r = try await clickhouseClient(for: alias).query("""
            SELECT engine, total_rows, total_bytes, comment FROM system.tables
            WHERE database = \(SQLBuilder.literal(database)) AND name = \(SQLBuilder.literal(table))
            """)
        guard let row = r.rows.first else { return Array(repeating: "", count: 15) }
        func f(_ i: Int) -> String { i < row.count && row[i] != "NULL" ? row[i] : "" }
        return [f(0), "", "", "", "", f(3), f(1), "", f(2), "", "", "", "", "", ""]
    }
}
