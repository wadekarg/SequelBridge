//
//  QueryRouteTests.swift
//  SequelBridgeTests
//
//  How the Query tab runs a statement (QueryRoute): refused, Explain's path, USE, as
//  typed, the app's own client, ClickHouse, the passthrough, or DuckDB's catalog. The
//  same decision QueryPanelView carries out, so the query corpus (QueryCorpusTests)
//  runs every kind of statement on the path the Query tab takes.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Query tab: which path a statement takes")
struct QueryRouteTests {
    let my = Connection(name: "Shop", alias: "shop", host: "127.0.0.1", username: "root", database: "shopdemo", engine: .mysql)
    var pg: Connection { var c = Connection(name: "CRM", alias: "crm", host: "127.0.0.1", username: "u", database: "crmdemo"); c.engine = .postgres; return c }
    let ch = Connection(name: "Logs", alias: "logs", host: "127.0.0.1", username: "u", database: "default", engine: .clickhouse)
    let lite = Connection(name: "Ref", alias: "ref", database: "/tmp/ref.sqlite", engine: .sqlite)

    /// Facts as after connecting: MySQL and PostgreSQL attached with their database and
    /// passthrough-capable; `readOnly` aliases read-only; `picked` the left panel's picks.
    func facts(readOnly: Set<String> = [], picked: [String: String] = [:], inTransaction: Bool = false) -> (String) -> QueryRoute.Facts {
        { alias in
            let attached = ["shop": "shopdemo", "crm": "crmdemo", "logs": "default", "ref": "main"][alias] ?? ""
            return QueryRoute.Facts(isReadOnly: readOnly.contains(alias),
                                    hasServerPassthrough: alias == "shop" || alias == "crm",
                                    attachedDatabase: attached, selectedDatabase: picked[alias], inTransaction: inTransaction)
        }
    }

    func route(_ sql: String, _ connections: [Connection], active: String? = nil,
               readOnly: Set<String> = [], picked: [String: String] = [:], inTransaction: Bool = false) -> QueryRoute {
        QueryRoute.plan(sql, connections: connections, active: active ?? connections.first?.alias,
                        facts: facts(readOnly: readOnly, picked: picked, inTransaction: inTransaction))
    }

    @Test("MySQL: reads to the server, writes as typed, SHOW on the app's client, EXPLAIN and USE their own ways")
    func mysql() {
        #expect(route("SELECT * FROM orders", [my]) == .passthrough(alias: "shop", serverSQL: "SELECT * FROM orders"))
        #expect(route("INSERT INTO orders VALUES (1)", [my]) == .asTyped(alias: "shop", serverSQL: "INSERT INTO orders VALUES (1)"))
        #expect(route("SHOW CREATE TABLE orders", [my]) == .native(alias: "shop", serverSQL: "SHOW CREATE TABLE orders", database: "shopdemo"))
        #expect(route("EXPLAIN SELECT * FROM orders", [my]) == .explain("SELECT * FROM orders"))
        #expect(route("USE crmdemo", [my]) == .use(alias: "shop", database: "crmdemo"))
        if case .refused = route("LOCK TABLES orders READ", [my]) {} else { Issue.record("LOCK TABLES ran") }
        // BEGIN stays DuckDB's: its transaction keeps one server connection.
        #expect(route("BEGIN", [my]) == .scanner(sql: "BEGIN", context: .init(alias: "shop", database: "shopdemo")))
        // Another database picked: unqualified names mean that one, which the passthrough can't see.
        #expect(route("SELECT * FROM orders", [my], picked: ["shop": "crmdemo"])
                == .scanner(sql: "SELECT * FROM orders", context: .init(alias: "shop", database: "crmdemo")))
    }

    @Test("PostgreSQL: reads to the server in public, by its own client in another schema; writes by its own client, in an open transaction as typed")
    func postgres() {
        #expect(route("SELECT 1", [pg]) == .passthrough(alias: "crm", serverSQL: "SELECT 1"))
        // The left panel picks public right after connecting: still the server's read.
        #expect(route("SELECT 7 / 2", [pg], picked: ["crm": "public"]) == .passthrough(alias: "crm", serverSQL: "SELECT 7 / 2"))
        #expect(route("SELECT * FROM daily", [pg], picked: ["crm": "reporting"])
                == .native(alias: "crm", serverSQL: "SELECT * FROM daily", database: "reporting"))
        #expect(route("SHOW search_path", [pg]) == .native(alias: "crm", serverSQL: "SHOW search_path", database: "public"))
        #expect(route("EXPLAIN SELECT 1", [pg]) == .explain("SELECT 1"))
        #expect(route("CREATE TABLE t (id int)", [pg]) == .native(alias: "crm", serverSQL: "CREATE TABLE t (id int)", database: "public"))
        #expect(route("VACUUM t", [pg]) == .native(alias: "crm", serverSQL: "VACUUM t", database: "public"))
        #expect(route("INSERT INTO t VALUES (1) RETURNING id", [pg])
                == .native(alias: "crm", serverSQL: "INSERT INTO t VALUES (1) RETURNING id", database: "public"))
        #expect(route("WITH gone AS (DELETE FROM t RETURNING *) SELECT count(*) FROM gone", [pg])
                == .native(alias: "crm", serverSQL: "WITH gone AS (DELETE FROM t RETURNING *) SELECT count(*) FROM gone", database: "public"))
        // Inside a transaction begun in the Query tab, in that transaction, so ROLLBACK undoes it.
        #expect(route("CREATE TABLE t (id int)", [pg], inTransaction: true) == .asTyped(alias: "crm", serverSQL: "CREATE TABLE t (id int)"))
        // A read in another schema too: on the transaction's connection (the engine puts the
        // schema first on its search_path), not the app's own client, which didn't see what
        // the transaction wrote.
        #expect(route("SELECT * FROM daily", [pg], picked: ["crm": "reporting"], inTransaction: true)
                == .passthrough(alias: "crm", serverSQL: "SELECT * FROM daily"))
        #expect(route("INSERT INTO daily VALUES (1)", [pg], picked: ["crm": "reporting"], inTransaction: true)
                == .asTyped(alias: "crm", serverSQL: "INSERT INTO daily VALUES (1)"))
        // A setting in that transaction: SET LOCAL, SET CONSTRAINTS and SET TRANSACTION end
        // with it, so they run in it; any other SET or RESET would outlast it on a connection
        // DuckDB reuses, and is refused, saying to write SET LOCAL. (It ran in DuckDB.)
        #expect(route("SET LOCAL statement_timeout = '5s'", [pg], inTransaction: true)
                == .asTyped(alias: "crm", serverSQL: "SET LOCAL statement_timeout = '5s'"))
        #expect(route("SET CONSTRAINTS ALL DEFERRED", [pg], inTransaction: true)
                == .asTyped(alias: "crm", serverSQL: "SET CONSTRAINTS ALL DEFERRED"))
        for setting in ["SET statement_timeout = '5s'", "SET SESSION timezone TO 'UTC'", "RESET statement_timeout", "SET ROLE reporting"] {
            guard case .refused(let why) = route(setting, [pg], inTransaction: true) else {
                Issue.record("\(setting) wasn't refused in a transaction"); continue
            }
            #expect(why.contains("SET LOCAL"), "\(why)")
        }
        #expect(route("SET search_path TO x", [pg], inTransaction: true) == .use(alias: "crm", database: "x"))
        // SET search_path picks the schema, as the left panel does; another lone SET runs there.
        #expect(route("SET search_path TO x", [pg]) == .use(alias: "crm", database: "x"))
        #expect(route("SET statement_timeout = '5s'", [pg]) == .native(alias: "crm", serverSQL: "SET statement_timeout = '5s'", database: "public"))
    }

    @Test("ClickHouse runs everything on its client; SQLite in SQLite itself, in an open transaction through DuckDB")
    func clickhouseAndSQLite() {
        #expect(route("SELECT 1", [ch]) == .clickhouse(alias: "logs", sql: "SELECT 1"))
        #expect(route("INSERT INTO t VALUES (1)", [ch]) == .clickhouse(alias: "logs", sql: "INSERT INTO t VALUES (1)"))
        #expect(route("SELECT datetime('now')", [lite], picked: ["ref": "main"])
                == .passthrough(alias: "ref", serverSQL: "SELECT datetime('now')"))
        #expect(route("INSERT OR REPLACE INTO t VALUES (1)", [lite], picked: ["ref": "main"])
                == .native(alias: "ref", serverSQL: "INSERT OR REPLACE INTO t VALUES (1)", database: "main"))
        #expect(route("BEGIN", [lite], picked: ["ref": "main"]) == .scanner(sql: "BEGIN", context: .init(alias: "ref", database: "main")))
        #expect(route("INSERT INTO t VALUES (1)", [lite], picked: ["ref": "main"], inTransaction: true)
                == .scanner(sql: "INSERT INTO t VALUES (1)", context: .init(alias: "ref", database: "main")))
    }

    @Test("several connections: a statement naming one server goes to it; naming none, to the one picked; naming two, across")
    func several() {
        let both = [my, pg]
        #expect(route("SELECT * FROM crm.contacts", both) == .passthrough(alias: "crm", serverSQL: "SELECT * FROM contacts"))
        #expect(route("SELECT 1", both, active: "crm") == .passthrough(alias: "crm", serverSQL: "SELECT 1"))
        #expect(route("SELECT * FROM shop.orders o JOIN crm.contacts c ON c.id = o.id", both) == .acrossServers)
        #expect(route("SELECT * FROM logs.hits", [my, ch]) == .clickhouse(alias: "logs", sql: SQLBuilder.clickhouseSoleServerSQL(
            "SELECT * FROM logs.hits", alias: "logs", database: "default")))
        #expect(route("SELECT 1", []) == .scanner(sql: "SELECT 1", context: nil))
    }

    @Test("a write is refused on a read-only connection, and only there: another connection open read-only doesn't block it")
    func readOnly() {
        guard case .refused(let reason) = route("DELETE FROM orders", [my], readOnly: ["shop"]) else {
            Issue.record("a write ran on a read-only connection"); return
        }
        #expect(reason.contains("Shop"))
        #expect(route("SELECT * FROM orders", [my], readOnly: ["shop"]) == .passthrough(alias: "shop", serverSQL: "SELECT * FROM orders"))
        // A read-only production server beside a writable one: writing to the writable one runs.
        #expect(route("INSERT INTO contacts VALUES (1)", [my, pg], active: "crm", readOnly: ["shop"])
                == .native(alias: "crm", serverSQL: "INSERT INTO contacts VALUES (1)", database: "public"))
        #expect(route("INSERT INTO crm.contacts VALUES (1)", [my, pg], active: "shop", readOnly: ["shop"])
                == .native(alias: "crm", serverSQL: "INSERT INTO contacts VALUES (1)", database: "public"))
        #expect(route("INSERT INTO shop.orders VALUES (1)", [my, pg], active: "crm")
                == .asTyped(alias: "shop", serverSQL: "INSERT INTO orders VALUES (1)"))
        // Writing to the read-only one is refused, naming it.
        guard case .refused(let named) = route("INSERT INTO shop.orders VALUES (1)", [my, pg], active: "crm", readOnly: ["shop"]) else {
            Issue.record("a write ran on the read-only connection"); return
        }
        #expect(named.contains("Shop"))
        // Across servers each connection guards itself: DuckDB attaches a read-only one
        // read-only, so copying from it runs and writing into it is refused there
        // (ReadOnlyEnforcementTests).
        #expect(route("INSERT INTO crm.contacts SELECT * FROM shop.orders", [my, pg], readOnly: ["shop"]) == .acrossServers)
    }

    // MARK: - From the review of the night's changes

    @Test("inside a transaction begun in the Query tab, nothing runs on a connection of its own: ROLLBACK must undo it")
    func transactionStaysTogether() {
        // A CALL can't join it (its rows leave the transaction's connection out of step), nor
        // run beside it where ROLLBACK can't undo it: it is refused, saying what to do.
        if case .refused(let why) = route("CALL archive()", [my], inTransaction: true) {
            #expect(why.contains("COMMIT"), "\(why)")
        } else { Issue.record("a CALL inside a transaction wasn't refused") }
        // A SET joins it: on a connection of its own, the next statement read the variable as NULL.
        #expect(route("SET @s = 'archived'", [my], inTransaction: true) == .asTyped(alias: "shop", serverSQL: "SET @s = 'archived'"))
        // A script that would share one connection runs statement by statement in it instead.
        #expect(QueryRoute.sessionScript(["SET @id = 5", "DELETE FROM t WHERE id = @id"], connections: [my], active: "shop",
                                         facts: facts(inTransaction: true)) == nil)
        #expect(QueryRoute.sessionScript(["PREPARE q AS SELECT 1", "EXECUTE q"], connections: [pg], active: "crm",
                                         facts: facts(inTransaction: true)) == nil)
    }

    @Test("a script that leaves a transaction open, or turns autocommit off, isn't run on a connection that then closes")
    func openTransactionScript() {
        // On a connection of its own, its work was rolled back when it closed, the grid saying Done.
        #expect(QueryRoute.sessionScript(["BEGIN", "UPDATE t SET a = 1"], connections: [my], active: "shop", facts: facts()) == nil)
        #expect(QueryRoute.sessionScript(["SET autocommit = 0", "UPDATE t SET a = 1"], connections: [my], active: "shop", facts: facts()) == nil)
        #expect(QueryRoute.sessionScript(["BEGIN", "UPDATE t SET a = 1", "COMMIT"], connections: [my], active: "shop", facts: facts()) != nil)
    }

    @Test("SET search_path picks the schema as PostgreSQL reads it: quoted or not, folded; DEFAULT and lists aren't picks; read-only allowed")
    func searchPathForms() {
        #expect(route("SET search_path TO 'app'", [pg]) == .use(alias: "crm", database: "app"))
        #expect(route("SET search_path = MySchema", [pg]) == .use(alias: "crm", database: "myschema"))
        #expect(route("SET search_path TO \"MySchema\"", [pg]) == .use(alias: "crm", database: "MySchema"))
        if case .use = route("SET search_path TO DEFAULT", [pg]) { Issue.record("DEFAULT taken for a schema") }
        if case .use = route("SET search_path TO a, b", [pg]) { Issue.record("a list taken for one schema") }
        #expect(route("SET search_path TO app", [pg], readOnly: ["crm"]) == .use(alias: "crm", database: "app"))
    }

    /// MariaDB's BEGIN NOT ATOMIC … END runs as one block: its rows come back (the app's own
    /// client, as for CALL), and it begins no transaction the Query tab would then wait on.
    @Test("MariaDB's BEGIN NOT ATOMIC block runs on the app's own client and opens no transaction")
    func anonymousBlock() {
        let block = "BEGIN NOT ATOMIC DECLARE x INT DEFAULT 41; SELECT x + 1; END"
        #expect(route(block, [my]) == .native(alias: "shop", serverSQL: block, database: "shopdemo"))
        #expect(QueryEffects.transactionChange(block) == nil)
        #expect(QueryEffects.transactionChange("BEGIN") == true)
        #expect(QueryEffects.transactionChange("BEGIN WORK") == true)
    }

    /// MySQL 8's WITH … DELETE went to the passthrough, which can't run a statement that
    /// returns no rows; a WITH whose string or name says DELETE was refused as a write.
    @Test("MySQL 8's WITH … DELETE runs as typed; a WITH whose strings or names say DELETE reads, read-only too")
    func dataModifyingWith() {
        let w = "WITH x AS (SELECT id FROM t WHERE old) DELETE FROM t WHERE id IN (SELECT id FROM x)"
        #expect(route(w, [my]) == .asTyped(alias: "shop", serverSQL: w))
        let r = #"WITH x AS (SELECT * FROM t WHERE action = "DELETE" OR `update` = 1) SELECT * FROM x"#
        #expect(route(r, [my], readOnly: ["shop"]) == .passthrough(alias: "shop", serverSQL: r))
        #expect(SQLBuilder.isReadOnly(r))
        #expect(!QueryEffects.isDataModifyingWith(r))
        #expect(QueryEffects.isDataModifyingWith(w))
    }

    @Test("MySQL: a WITH whose string says DELETE is still a read; SET GLOBAL runs as typed, not with the one-run note")
    func mysqlEdges() {
        #expect(route(#"WITH x AS (SELECT * FROM t WHERE action = "DELETE") SELECT * FROM x"#, [my])
                == .passthrough(alias: "shop", serverSQL: #"WITH x AS (SELECT * FROM t WHERE action = "DELETE") SELECT * FROM x"#))
        #expect(route("SET GLOBAL max_connections = 200", [my]) == .asTyped(alias: "shop", serverSQL: "SET GLOBAL max_connections = 200"))
        #expect(route("SET PERSIST max_connections = 200", [my]) == .asTyped(alias: "shop", serverSQL: "SET PERSIST max_connections = 200"))
    }

    /// Before each PostgreSQL statement of a Query-tab transaction: the schema picked first on
    /// that transaction's search_path, built from the session's own path each time, so a pick
    /// later in the transaction takes over and public goes back to the session's path.
    @Test("in a Query-tab transaction on PostgreSQL, the schema picked goes first on the transaction's search_path")
    func transactionSearchPath() {
        let own = "(SELECT reset_val FROM pg_settings WHERE name = 'search_path')"
        #expect(QueryEngine.transactionSearchPath("reporting")
                == "SELECT set_config('search_path', '\"reporting\", ' || \(own), true)")
        #expect(QueryEngine.transactionSearchPath("public") == "SELECT set_config('search_path', \(own), true)")
        #expect(QueryEngine.transactionSearchPath(nil) == "SELECT set_config('search_path', \(own), true)")
        #expect(QueryEngine.transactionSearchPath(#"o'neil "x""#)
                == "SELECT set_config('search_path', '\"o''neil \"\"x\"\"\", ' || \(own), true)")
    }
}
