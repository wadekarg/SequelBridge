//
//  ConnectionManager.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import Combine
import Foundation
import os

@MainActor
class ConnectionManager: ObservableObject {
    // Swift 6.3 InferIsolatedConformances requires an explicit nonisolated
    // publisher. Declaring objectWillChange ourselves, however, silently disables
    // @Published's automatic change notifications — so these properties drive the
    // publisher manually via willSet. Without this, mutating `saved`/`active` does
    // not refresh SwiftUI (a new connection stayed invisible until relaunch).
    nonisolated let objectWillChange = ObservableObjectPublisher()

    var saved: [Connection] = []      { willSet { objectWillChange.send() } }
    var active: [Connection] = []     { willSet { objectWillChange.send() } }
    var connectionError: String?      { willSet { objectWillChange.send() } }
    /// The changed SSH server key the last Test Connection stopped at, for "Forget the Old
    /// Key…"; nil once that is done or another test starts. (Connect throws it.)
    var hostKeyChange: SSHHostKeyChange? { willSet { objectWillChange.send() } }
    /// Connections whose SSH tunnel closed on its own (the Mac slept, the network dropped):
    /// the workspace says so and offers Reconnect. Every statement on them failed, naming
    /// only an internal port, until the user went back Home.
    var droppedTunnels: Set<String> = [] { willSet { objectWillChange.send() } }

    private let store: ConnectionStore
    /// True when launched with `-SBConnectionsFile`: the list comes from a read-only
    /// fixture whose passwords are inline (demo and screenshot instances).
    let isFixtureBacked: Bool
    private(set) var queryEngine: QueryEngine
    private var directConns: [String: MySQLDirectConnection] = [:]

    init(arguments: [String] = CommandLine.arguments) throws {
        queryEngine = try QueryEngine()
        if let fixture = ConnectionStore.fixtureURL(from: arguments) {
            store = ConnectionStore(fileURL: fixture, fixture: true)
            isFixtureBacked = true
        } else {
            store = ConnectionStore(arguments: arguments)
            isFixtureBacked = false
        }
        saved = (try? store.load()) ?? []
        queryEngine.onTunnelDrop = { [weak self] alias in self?.droppedTunnels.insert(alias) }
    }

    /// The password to connect with: a fixture's inline password when there is one,
    /// else the Keychain item saved for this connection. A SQLite file has no
    /// password to find, so nothing stored means an empty one, not a refusal.
    func password(for conn: Connection) -> String? {
        if let inline = store.inlinePasswords[conn.id] { return inline }
        if let stored = Keychain.load(for: conn.id) { return stored }
        return conn.engine == .sqlite ? "" : nil
    }

    // MARK: - Saved connection management

    /// Re-reads the saved list from disk. The sheets call this on dismiss: an
    /// append during sheet dismissal does not reliably reach the List on macOS,
    /// so the list is refreshed from the store it was just written to.
    func reloadSaved() {
        saved = (try? store.load()) ?? saved
    }

    func addSaved(_ conn: Connection, password: String) throws {
        saved.append(conn)
        Keychain.save(password, for: conn.id)
        try store.save(saved)
    }

    func updateSaved(_ conn: Connection, password: String?) throws {
        guard let idx = saved.firstIndex(where: { $0.id == conn.id }) else { return }
        saved[idx] = conn
        if let pw = password {
            Keychain.save(pw, for: conn.id)
        }
        try store.save(saved)
    }

    func deleteSaved(id: UUID) throws {
        saved.removeAll { $0.id == id }
        Keychain.delete(for: id)
        for kind in SSHLoginPrompt.keychainKinds { Keychain.delete(for: id, kind: kind) }
        try store.save(saved)
    }

    // MARK: - Connecting / disconnecting

    func connect(_ connections: [Connection]) async throws {
        connectionError = nil
        // Returning to Home from a workspace does NOT detach — the shared engine
        // keeps the previous workspace's aliases ATTACHed. Re-ATTACHing an existing
        // alias throws (DuckDB "database already exists"), which surfaced to the user
        // as "Connection query failed" on the second connect. Reset to a clean slate:
        // detach any previously-active aliases and any alias we're about to (re)attach.
        let staleAliases = Set(active.map(\.alias)).union(connections.map(\.alias))
        for alias in staleAliases {
            try? await queryEngine.detach(alias)
        }
        directConns.removeAll()
        active = []
        droppedTunnels.subtract(staleAliases)

        var attached: [String] = []
        do {
            for c in connections {
                guard let password = password(for: c) else {
                    throw ConnectionError.missingPassword(c.name)
                }
                try await queryEngine.attach(c, password: password)
                attached.append(c.alias)
                directConns[c.alias] = MySQLDirectConnection(c, password: password)
            }
        } catch {
            // Those attached before the failure go too: they stayed attached, their SSH
            // tunnels running, until the app quit.
            for alias in attached {
                try? await queryEngine.detach(alias)
                directConns.removeValue(forKey: alias)
            }
            throw error
        }
        active = connections
    }

    /// Opens one more connection beside those open (a workspace's + button), as Connect
    /// does: it joins `active`, so the next Connect from Home closes it too (attached on
    /// its own, it stayed attached, its SSH tunnel running, until the app quit).
    func add(_ conn: Connection) async throws {
        guard !active.contains(where: { $0.alias == conn.alias }) else { return }
        guard let password = password(for: conn) else { throw ConnectionError.missingPassword(conn.name) }
        try await queryEngine.attach(conn, password: password)
        directConns[conn.alias] = MySQLDirectConnection(conn, password: password)
        active.append(conn)
    }

    /// Opens a connection whose SSH tunnel closed again: a new tunnel (ssh may ask its
    /// questions again) and the same attachment, on the database it was on.
    func reconnect(_ alias: String) async throws {
        guard let conn = active.first(where: { $0.alias == alias }) else { return }
        guard let password = password(for: conn) else { throw ConnectionError.missingPassword(conn.name) }
        try? await queryEngine.detach(alias)
        try await queryEngine.attach(conn, password: password)
        directConns[alias] = MySQLDirectConnection(conn, password: password)
        droppedTunnels.remove(alias)
    }

    func disconnect(_ alias: String) {
        droppedTunnels.remove(alias)
        directConns.removeValue(forKey: alias)
        active.removeAll { $0.alias == alias }
        // detach() is now serialized through the query actor, so it is async. UI
        // state is cleaned up synchronously; the DuckDB DETACH runs on the actor
        // (queued behind any in-flight query) so it never races the handle.
        Task { try? await queryEngine.detach(alias) }
    }

    func directConnection(for alias: String) -> MySQLDirectConnection? {
        directConns[alias]
    }

    /// Puts `alias` on `database` and lists its tables: the database picked at the top of
    /// the left panel, or by a `USE` in the Query tab. A MySQL/Postgres connection is
    /// attached again with `database` as its DSN default, because the fast server
    /// passthrough resolves unqualified names in the attach's database; then the
    /// database becomes the query context.
    ///
    /// One switch per connection runs at a time, and the newest request wins: a request
    /// a later one overtook ends in CancellationError without touching the connection.
    /// When the database can't be opened, the connection goes back to the database it
    /// had, and the error says why.
    func switchDatabase(alias: String, to database: String) async throws -> [TableInfo] {
        let ticket = (switchTickets[alias] ?? 0) + 1
        switchTickets[alias] = ticket
        let earlier = switchQueue[alias]
        let work = Task { @MainActor () -> Result<[TableInfo], Error> in
            await earlier?.value
            guard self.switchTickets[alias] == ticket else { return .failure(CancellationError()) }
            do { return .success(try await self.performSwitch(alias: alias, to: database)) }
            catch { return .failure(error) }
        }
        switchQueue[alias] = Task { _ = await work.value }
        return try await work.value.get()
    }

    private func performSwitch(alias: String, to database: String) async throws -> [TableInfo] {
        let before = queryEngine.attachedDatabase(alias)
        do {
            try await reattach(alias, on: database)
            // Listing proves the database can be used: an attach can succeed and the
            // first statement on it fail.
            let tables = try await queryEngine.fetchTables(alias: alias, database: database)
            await queryEngine.setDefaultContextAwaited(alias: alias, database: database)
            return tables
        } catch {
            Log.connections.error("switchDatabase(\(alias, privacy: .public), \(database, privacy: .public)) failed: \(QueryEngine.extractReason(from: error), privacy: .public)")
            if queryEngine.attachedDatabase(alias) != before { try? await reattach(alias, on: before) }
            if !before.isEmpty { await queryEngine.setDefaultContextAwaited(alias: alias, database: before) }
            throw error
        }
    }

    /// Attaches a MySQL `alias` again with `database` as its default. A failed attach puts
    /// the previous one back before the error is thrown. Other engines, and a connection
    /// already on `database`, are left as they are: on PostgreSQL the picker lists schemas
    /// of the one database the connection opened, so picking one opens nothing new.
    private func reattach(_ alias: String, on database: String) async throws {
        guard let idx = active.firstIndex(where: { $0.alias == alias }) else { return }
        let current = active[idx]
        guard current.engine == .mysql,
              queryEngine.attachedDatabase(alias) != database,
              let password = password(for: current) else { return }
        var target = current
        target.database = database
        // Through the same SSH tunnel: no second login, no second one-time code.
        try await queryEngine.detach(alias, keepingTunnel: true)
        do {
            try await queryEngine.attach(target, password: password)
        } catch {
            try? await queryEngine.attach(current, password: password)
            throw error
        }
        active[idx] = target
        directConns[alias] = MySQLDirectConnection(target, password: password)
    }

    private var switchTickets: [String: Int] = [:]
    private var switchQueue: [String: Task<Void, Never>] = [:]

    // MARK: - Test connection before saving

    /// Returns nil on success, or an error message string on failure.
    func testConnection(_ conn: Connection, password: String) async -> String? {
        hostKeyChange = nil
        let tempAlias = "__test_\(conn.alias)"
        var testConn = conn
        testConn.alias = tempAlias
        do {
            try await queryEngine.attach(testConn, password: password)
            try await queryEngine.detach(tempAlias)
            return nil   // success
        } catch {
            try? await queryEngine.detach(tempAlias)
            hostKeyChange = error as? SSHHostKeyChange
            let msg = error.localizedDescription
            Log.connections.error("testConnection failed: \(msg, privacy: .public)")
            return msg
        }
    }
}

extension ConnectionManager {
    /// Forgets the changed server's old key and trusts the new one the user confirmed, so
    /// the next connect or test goes through without asking again (SSHTunnel.forget).
    func forgetHostKey(_ change: SSHHostKeyChange) throws {
        try SSHTunnel.forget(change)
        hostKeyChange = nil
    }
}

enum ConnectionError: LocalizedError {
    case missingPassword(String)

    var errorDescription: String? {
        switch self {
        case .missingPassword(let name):
            return "No password found for \(name). Please re-add the connection."
        }
    }
}

enum SequelBridgeError: LocalizedError {
    case sshNotImplemented
    case attachFailed(String)
    case readOnly(String)

    var errorDescription: String? {
        switch self {
        case .sshNotImplemented:
            return "SSH connections are not yet supported. Coming in Phase 2."
        case .attachFailed(let reason):
            return reason
        case .readOnly(let name):
            return "“\(name)” is open in read-only mode. Turn off read-only in the connection settings to make changes."
        }
    }
}
