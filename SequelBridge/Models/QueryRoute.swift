//
//  QueryRoute.swift
//  SequelBridge
//
//  How the Query tab runs one statement: refused, on the server as typed, on the app's
//  own client, through the server passthrough, on ClickHouse, or through DuckDB's
//  catalog. The decision only, apart from the view, so tests can put every kind of
//  statement through the path the Query tab takes (QueryPanelView.runTypedQuery carries
//  it out). A statement naming two or more servers is planned by the view.
//

import Foundation

enum QueryRoute: Equatable {
    /// What the route depends on for one open connection.
    struct Facts: Equatable {
        var isReadOnly = false
        var hasServerPassthrough = false
        /// The database the connection is attached with (its DSN default).
        var attachedDatabase = ""
        /// The database picked at the top of the left panel, if one was.
        var selectedDatabase: String?
        /// A transaction begun in the Query tab is open (DuckDB's, one for every connection).
        var inTransaction = false
    }

    /// Not run, and why (a write on a read-only connection, LOCK TABLES on MySQL).
    case refused(String)
    /// A typed EXPLAIN on MySQL or PostgreSQL: the Explain button's path, for the statement after it.
    case explain(String)
    /// `USE db` on MySQL: the same switch as picking `db` in the left panel.
    case use(alias: String, database: String)
    /// A statement that returns no rows, on the server as typed (MySQL, PostgreSQL).
    case asTyped(alias: String, serverSQL: String)
    /// A statement the passthrough can't run, on the app's own client for the server.
    case native(alias: String, serverSQL: String, database: String)
    /// ClickHouse, on its HTTP client.
    case clickhouse(alias: String, sql: String)
    /// A read on one MySQL or PostgreSQL server, pushed to it whole.
    case passthrough(alias: String, serverSQL: String)
    /// Through DuckDB's catalog, after `USE alias.database` when `context` is set.
    case scanner(sql: String, context: Context?)
    /// Names two or more servers, or one in a way only a plan across the catalog runs.
    case acrossServers

    struct Context: Equatable { let alias: String; let database: String }

    /// The route for one statement (`sql`, already split from a script).
    static func plan(_ sql: String, connections: [Connection], active: String?,
                     facts: (String) -> Facts) -> QueryRoute {
        let target = SQLBuilder.soleTarget(of: sql, connections: connections, active: active)
        // USE on MySQL, SET search_path TO x on PostgreSQL: the same as picking it in the left
        // panel. Before the read-only check: they move the session, they write nothing.
        if let db = QueryEffects.soleUse(sql), let target, target.engine == .mysql || target.engine == .postgres {
            return .use(alias: target.alias, database: db)
        }
        // Safe mode: a write to a read-only connection is refused before any path runs it
        // (EXPLAIN ANALYZE of a write runs the write). Only that one: a read-only server open
        // beside a writable one refused every write to the writable one too. A statement
        // naming several servers is guarded by each (DuckDB attaches a read-only one read-only).
        if !SQLBuilder.isReadOnly(sql), let target, facts(target.alias).isReadOnly {
            return .refused(SequelBridgeError.readOnly(target.name).errorDescription ?? "The connection is read-only.")
        }
        // A typed EXPLAIN takes the Explain button's path on MySQL and PostgreSQL: through
        // the passthrough MariaDB can't prepare it, and PostgreSQL can't nest it.
        if let inner = SQLBuilder.strippedExplain(sql), let target,
           target.engine == .mysql || target.engine == .postgres {
            return .explain(inner)
        }
        // LOCK TABLES and SET autocommit would outlive the statement on a server connection
        // the app reuses.
        if let target, target.engine == .mysql, let reason = QueryEffects.refusal(sql) {
            return .refused(reason)
        }
        // A procedure's rows would leave the transaction's connection out of step; on a
        // connection of its own a ROLLBACK couldn't undo it.
        if let target, target.engine == .mysql, facts(target.alias).inTransaction, QueryEffects.isCall(sql) {
            return .refused("CALL isn't run inside a transaction begun in the Query tab: a procedure's rows would leave "
                + "the transaction's connection out of step. COMMIT or ROLLBACK first, or run BEGIN; CALL …; COMMIT together.")
        }

        func native(_ conn: Connection) -> QueryRoute? {
            guard QueryEffects.runsOnNativeClient(sql, engine: conn.engine) else { return nil }
            // Inside a transaction begun in the Query tab a CALL joins it (as typed): on a
            // connection of its own a ROLLBACK couldn't undo it.
            if facts(conn.alias).inTransaction, !SQLBuilder.isReadOnly(sql) { return nil }
            return .native(alias: conn.alias, serverSQL: SQLBuilder.stripAliasPrefix(sql, alias: conn.alias),
                           database: catalogDatabase(conn.alias, connections: connections, facts: facts))
        }
        // A read on the database the connection is attached with: mysql_query and
        // postgres_query run on that default schema, so only then do unqualified names
        // mean on the server what they mean here.
        func passthrough(_ conn: Connection) -> QueryRoute? {
            let f = facts(conn.alias)
            guard f.hasServerPassthrough, !f.attachedDatabase.isEmpty, SQLBuilder.isRowReturning(sql),
                  !QueryEffects.isDataModifyingWith(sql) else { return nil }
            let serverSQL = SQLBuilder.stripAliasPrefix(sql, alias: conn.alias)
            if conn.engine == .postgres {
                // The picker lists schemas, and postgres_query reads with the server's own
                // search_path: public's names mean there what they mean here. In another
                // schema the app's own client reads, with search_path set to it. (Compared
                // with the database's name, the pick never matched, and every read went
                // through DuckDB: 7 / 2 was 3.5, a regex matched nothing, arrays were NULL.)
                // Inside a transaction begun in the Query tab, in that transaction whatever the
                // schema: the engine puts it first on the transaction's search_path. The app's
                // own client didn't see what the transaction wrote.
                let schema = f.selectedDatabase ?? "public"
                return schema == "public" || f.inTransaction ? .passthrough(alias: conn.alias, serverSQL: serverSQL)
                    : .native(alias: conn.alias, serverSQL: serverSQL, database: schema)
            }
            guard (f.selectedDatabase ?? f.attachedDatabase) == f.attachedDatabase else { return nil }
            return .passthrough(alias: conn.alias, serverSQL: serverSQL)
        }
        // A SQLite file: in SQLite itself, in its own SQL. Inside a transaction begun in the
        // Query tab, in that transaction (DuckDB's) instead, so ROLLBACK undoes it.
        // A read streams from SQLite (DuckDB's sqlite_query); the rest runs in SQLite's tool.
        func sqlite(_ conn: Connection) -> QueryRoute? {
            guard conn.engine == .sqlite, !facts(conn.alias).inTransaction, !QueryEffects.isTransactionControl(sql) else { return nil }
            let own = SQLBuilder.stripAliasPrefix(sql, alias: conn.alias)
            return SQLBuilder.isRowReturning(sql) ? .passthrough(alias: conn.alias, serverSQL: own)
                : .native(alias: conn.alias, serverSQL: own, database: "main")
        }
        // On PostgreSQL, a statement that changes something runs on the app's own client, in
        // a transaction of its own as psql runs it: DuckDB's postgres_execute wraps it in one
        // of DuckDB's, where VACUUM, CREATE INDEX CONCURRENTLY and CREATE DATABASE can't run,
        // and RETURNING's rows were lost. Inside a transaction begun in the Query tab it goes
        // to that transaction instead (asTyped), so ROLLBACK undoes it.
        func postgresWrite(_ conn: Connection) -> QueryRoute? {
            guard conn.engine == .postgres, !facts(conn.alias).inTransaction,
                  QueryEffects.runsAsTyped(sql, engine: .postgres) || QueryEffects.isDataModifyingWith(sql) else { return nil }
            return .native(alias: conn.alias, serverSQL: SQLBuilder.stripAliasPrefix(sql, alias: conn.alias),
                           database: catalogDatabase(conn.alias, connections: connections, facts: facts))
        }

        let named = connections.filter { SQLBuilder.referencesAlias(sql, $0.alias) }
        if connections.count <= 1 || named.isEmpty {
            // One connection, or a statement naming no server: the connection picked at the
            // top of the left panel.
            guard let conn = target else { return .scanner(sql: sql, context: nil) }
            if conn.engine == .clickhouse { return .clickhouse(alias: conn.alias, sql: sql) }
            if let route = sqlite(conn) ?? native(conn) ?? passthrough(conn) ?? postgresWrite(conn) { return route }
            // A setting inside a transaction begun in the Query tab, on PostgreSQL: SET LOCAL
            // (SET CONSTRAINTS, SET TRANSACTION) ends with the transaction, so it runs in it;
            // any other SET or RESET would outlast it on a connection DuckDB goes on to reuse.
            // (Both ran in DuckDB, which took a timezone setting for its own.)
            if conn.engine == .postgres, facts(conn.alias).inTransaction, QueryEffects.isSessionSetting(sql) {
                guard QueryEffects.isTransactionScopedSetting(sql) else { return .refused(QueryEffects.transactionSettingRefusal) }
                return .asTyped(alias: conn.alias, serverSQL: SQLBuilder.stripAliasPrefix(sql, alias: conn.alias))
            }
            // A lone SET: on the server, where it means something, and saying it lasts for
            // its run only (DuckDB refused PostgreSQL's own settings).
            // Inside a transaction begun in the Query tab, it joins that (as typed): on a
            // connection of its own the next statement read the variable as NULL.
            if conn.engine == .mysql || conn.engine == .postgres, QueryEffects.isSessionSetting(sql),
               !facts(conn.alias).inTransaction, !(conn.engine == .mysql && QueryEffects.isPersistentSetting(sql)) {
                return .native(alias: conn.alias, serverSQL: SQLBuilder.stripAliasPrefix(sql, alias: conn.alias),
                               database: catalogDatabase(conn.alias, connections: connections, facts: facts))
            }
            if conn.engine == .mysql || conn.engine == .postgres, QueryEffects.runsAsTyped(sql, engine: conn.engine) {
                return .asTyped(alias: conn.alias, serverSQL: SQLBuilder.stripAliasPrefix(sql, alias: conn.alias))
            }
            // Writes, DDL and databases other than the attached one: DuckDB's catalog, after USE.
            let db = facts(conn.alias).selectedDatabase ?? conn.database
            return .scanner(sql: sql, context: Context(alias: conn.alias, database: db))
        }
        if named.count == 1 {
            let conn = named[0]
            if conn.engine == .clickhouse {
                // Outside DuckDB's catalog: the alias becomes the database the panel picked.
                return .clickhouse(alias: conn.alias, sql: SQLBuilder.clickhouseSoleServerSQL(
                    sql, alias: conn.alias, database: catalogDatabase(conn.alias, connections: connections, facts: facts)))
            }
            if let route = sqlite(conn) ?? native(conn) ?? passthrough(conn) ?? postgresWrite(conn) { return route }
            // A write naming only this server runs on it as typed, as with one connection
            // open: through DuckDB's catalog its own syntax failed.
            if conn.engine == .mysql || conn.engine == .postgres, QueryEffects.runsAsTyped(sql, engine: conn.engine) {
                return .asTyped(alias: conn.alias, serverSQL: SQLBuilder.stripAliasPrefix(sql, alias: conn.alias))
            }
        }
        return .acrossServers
    }

    /// A script the Query tab runs on one connection of the server's own client, its
    /// statements sharing what each sets (QueryEffects.needsOneSession), or refused.
    enum SessionScript: Equatable {
        case run(alias: String, statements: [String], database: String)
        case refused(String)
    }

    /// `statements` (a script, already split) when they need one connection and all run on
    /// one MySQL or PostgreSQL server; nil when each statement takes its own route.
    static func sessionScript(_ statements: [String], connections: [Connection], active: String?,
                              facts: (String) -> Facts) -> SessionScript? {
        let targets = statements.map { SQLBuilder.soleTarget(of: $0, connections: connections, active: active) }
        // Inside a transaction begun in the Query tab, each statement joins it instead.
        guard let target = targets.first ?? nil, targets.allSatisfy({ $0?.alias == target.alias }),
              target.engine == .mysql || target.engine == .postgres || target.engine == .sqlite,
              !facts(target.alias).inTransaction,
              QueryEffects.needsOneSession(statements, engine: target.engine) else { return nil }
        if facts(target.alias).isReadOnly, statements.contains(where: { !SQLBuilder.isReadOnly($0) }) {
            return .refused(SequelBridgeError.readOnly(target.name).errorDescription ?? "The connection is read-only.")
        }
        return .run(alias: target.alias, statements: statements.map { SQLBuilder.stripAliasPrefix($0, alias: target.alias) },
                    database: catalogDatabase(target.alias, connections: connections, facts: facts))
    }

    /// The database DuckDB's catalog path puts between `alias` and a table: the left
    /// panel's pick, else PostgreSQL's "public", SQLite's "main", or the database the
    /// connection is attached with.
    static func catalogDatabase(_ alias: String, connections: [Connection], facts: (String) -> Facts) -> String {
        let f = facts(alias)
        if let picked = f.selectedDatabase { return picked }
        switch connections.first(where: { $0.alias == alias })?.engine {
        case .postgres: return "public"
        case .sqlite:   return "main"
        default:        return f.attachedDatabase
        }
    }
}
