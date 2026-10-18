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

        for c in connections {
            guard let password = password(for: c) else {
                throw ConnectionError.missingPassword(c.name)
            }
            try await queryEngine.attach(c, password: password)
            directConns[c.alias] = MySQLDirectConnection(c, password: password)
        }
        active = connections
    }

    func disconnect(_ alias: String) {
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

    /// Re-attaches a MySQL/Postgres `alias` with `database` as its DSN default so the
    /// fast server passthrough applies: it needs a database in the connection string
    /// (a connection saved without a database otherwise falls back to the
    /// slower scanner and can't push LIMIT/WHERE to the server). Called when the user
    /// picks a database in the sidebar. No-op if the connection is already attached with
    /// that database, or isn't a passthrough engine.
    func adoptDatabase(alias: String, database: String) async {
        guard !database.isEmpty,
              let idx = active.firstIndex(where: { $0.alias == alias }) else { return }
        let conn = active[idx]
        guard conn.engine == .mysql || conn.engine == .postgres,
              queryEngine.attachedDatabase(alias) != database,
              let password = password(for: conn) else { return }
        var adopted = conn
        adopted.database = database
        do {
            try await queryEngine.detach(alias)
            try await queryEngine.attach(adopted, password: password)
            active[idx] = adopted
            directConns[alias] = MySQLDirectConnection(adopted, password: password)
        } catch {
            Log.connections.error("adoptDatabase(\(alias, privacy: .public), \(database, privacy: .public)) failed: \(QueryEngine.extractReason(from: error), privacy: .public)")
        }
    }

    // MARK: - Test connection before saving

    /// Returns nil on success, or an error message string on failure.
    func testConnection(_ conn: Connection, password: String) async -> String? {
        let tempAlias = "__test_\(conn.alias)"
        var testConn = conn
        testConn.alias = tempAlias
        do {
            try await queryEngine.attach(testConn, password: password)
            try await queryEngine.detach(tempAlias)
            return nil   // success
        } catch {
            try? await queryEngine.detach(tempAlias)
            let msg = error.localizedDescription
            Log.connections.error("testConnection failed: \(msg, privacy: .public)")
            return msg
        }
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
