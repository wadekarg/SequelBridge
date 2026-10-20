//
//  WorkspaceSession+Databases.swift
//  SequelBridge
//
//  The database picked at the top of the left panel, and the tables listed under it.
//

import Foundation

extension WorkspaceSession {

    /// Lists `conn`'s databases, picks the saved one (else the first), and lists its tables.
    func loadDatabases(for conn: Connection, manager: ConnectionManager) async {
        do {
            let dbs = try await manager.queryEngine.fetchDatabases(alias: conn.alias)
            availableDatabases[conn.alias] = dbs
            // PostgreSQL's picker lists schemas; its own default is public.
            let picked = selectedDatabase[conn.alias] ?? dbs.first(where: { $0 == conn.database })
                ?? (conn.engine == .postgres ? dbs.first(where: { $0 == "public" }) : nil) ?? dbs.first ?? ""
            await showDatabase(picked, for: conn, manager: manager)
        } catch { availableDatabases[conn.alias] = [] }
    }

    /// Picks `database` for `conn` and lists its tables. The list reads "Loading tables…"
    /// meanwhile. If the database can't be opened, the pick goes back to the database the
    /// connection is still on, and the panel says why, with Try Again.
    func showDatabase(_ database: String, for conn: Connection, manager: ConnectionManager) async {
        let alias = conn.alias
        // Another database closes the table open from the one before: Content kept its
        // rows while reads and edits went to the newly picked database, where a table of
        // the same name took them.
        if database != shownDatabase[alias] { selectedTables[alias] = nil }
        selectedDatabase[alias] = database
        sidebarTrees[alias] = nil
        tableListError[alias] = nil
        guard !database.isEmpty else { sidebarTrees[alias] = []; return }
        do {
            let tables = try await manager.switchDatabase(alias: alias, to: database)
            guard selectedDatabase[alias] == database else { return }   // a later pick fills the list
            sidebarTrees[alias] = tables
            shownDatabase[alias] = database
        } catch is CancellationError {
            // A later pick took over and fills the list.
        } catch {
            guard selectedDatabase[alias] == database else { return }
            let back = shownDatabase[alias] ?? conn.database
            selectedDatabase[alias] = back
            if !back.isEmpty { await loadTables(for: conn, manager: manager) }
            tableListError[alias] = TableListError(
                database: database, message: "Couldn't open \(database): \(QueryEngine.extractReason(from: error))")
        }
    }

    /// After a Query-tab run on `conn` succeeded: a `USE` picks that database, dropping
    /// the picked database goes back to the saved one, and DDL re-reads the lists.
    func followRun(_ sql: String, on conn: Connection, manager: ConnectionManager) async {
        let alias = conn.alias
        let current = selectedDatabase[alias]
        let outcome = QueryEffects.afterRun(sql, database: current)
        // Databases are MySQL's to switch with USE; other engines only re-read their lists.
        if conn.engine == .mysql, outcome.database != current {
            let dbs = availableDatabases[alias] ?? []
            if let db = outcome.database {
                if !dbs.contains(db) { availableDatabases[alias] = (dbs + [db]).sorted() }   // so the picker can show it
                await showDatabase(db, for: conn, manager: manager)
            } else {
                // The picked database was dropped: back to the saved one, else the first other one.
                let others = dbs.filter { $0 != current }
                await showDatabase(others.first(where: { $0 == conn.database }) ?? others.first ?? "", for: conn, manager: manager)
            }
        } else if outcome.reloadTables {
            await loadTables(for: conn, manager: manager)
        }
        // After any switch: on a dropped database the connection can't list anything.
        if outcome.reloadDatabases, let dbs = try? await manager.queryEngine.fetchDatabases(alias: alias) {
            // A USE can pick a database the list leaves out (a system schema): keep it listed.
            let picked = selectedDatabase[alias] ?? ""
            availableDatabases[alias] = picked.isEmpty || dbs.contains(picked) ? dbs : (dbs + [picked]).sorted()
        }
    }

    /// Add Database…: makes it, lists it and picks it, as in Sequel Ace. Returns the
    /// server's reason when it refuses.
    func createDatabase(_ name: String, charset: String, collation: String, on conn: Connection,
                        manager: ConnectionManager) async -> String? {
        let sql = SQLBuilder.createDatabase(name, charset: charset, collation: collation)
        do { _ = try await manager.queryEngine.runAsTyped(alias: conn.alias, sql: sql) }
        catch { return QueryEngine.extractReason(from: error) }
        await followRun(sql, on: conn, manager: manager)       // re-reads the database list
        await showDatabase(name, for: conn, manager: manager)
        return nil
    }

    /// Delete Database…: drops it. When it was the one picked, the connection's own
    /// database is picked again, as after a typed DROP DATABASE. Returns the server's
    /// reason when it refuses.
    func deleteDatabase(_ name: String, on conn: Connection, manager: ConnectionManager) async -> String? {
        let sql = SQLBuilder.dropDatabase(name)
        do { _ = try await manager.queryEngine.runAsTyped(alias: conn.alias, sql: sql) }
        catch { return QueryEngine.extractReason(from: error) }
        await followRun(sql, on: conn, manager: manager)
        return nil
    }

    /// Refresh Tables (⌃⌘R): re-reads the picked database's tables.
    func refreshTables(for conn: Connection, manager: ConnectionManager) async {
        await loadTables(for: conn, manager: manager)
    }

    /// Refresh Databases (⇧⌘R): re-reads the database list and the picked one's tables.
    /// A picked database that is gone goes back to the connection's own, else the first.
    func refreshDatabases(for conn: Connection, manager: ConnectionManager) async {
        let alias = conn.alias
        var dbs = try? await manager.queryEngine.fetchDatabases(alias: alias)
        if dbs == nil {
            // On a database dropped elsewhere every statement fails: go back to the
            // connection's own database first, then read the list again.
            let picked = selectedDatabase[alias]
            let back = conn.database.isEmpty ? (availableDatabases[alias]?.first { $0 != picked } ?? "") : conn.database
            if !back.isEmpty { await showDatabase(back, for: conn, manager: manager) }
            dbs = try? await manager.queryEngine.fetchDatabases(alias: alias)
        }
        guard let dbs else { return }
        availableDatabases[alias] = dbs
        let picked = selectedDatabase[alias] ?? ""
        if !picked.isEmpty, !dbs.contains(picked) {
            await showDatabase(dbs.first(where: { $0 == conn.database }) ?? dbs.first ?? "", for: conn, manager: manager)
        } else {
            await loadTables(for: conn, manager: manager)
        }
    }

    /// Re-reads the tables of the database selected for `conn`.
    func loadTables(for conn: Connection, manager: ConnectionManager) async {
        let alias = conn.alias
        let db = selectedDatabase[alias] ?? conn.database
        guard !db.isEmpty else { return }
        do {
            let tables = try await manager.queryEngine.fetchTables(alias: alias, database: db)
            guard (selectedDatabase[alias] ?? conn.database) == db else { return }
            sidebarTrees[alias] = tables
            tableListError[alias] = nil
            shownDatabase[alias] = db
        } catch {
            guard (selectedDatabase[alias] ?? conn.database) == db else { return }
            sidebarTrees[alias] = []
            tableListError[alias] = TableListError(
                database: db, message: "Couldn't list the tables of \(db): \(QueryEngine.extractReason(from: error))")
        }
    }
}
