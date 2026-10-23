//
//  DatabaseEngine.swift
//  SequelBridge
//
//  Which database product a connection talks to. This is a separate axis from
//  ConnectionType, which describes how the connection is *carried* (TCP, socket,
//  SSH tunnel) — a Postgres server can be reached over any of them.
//

import Foundation

nonisolated enum DatabaseEngine: String, Codable, CaseIterable, Identifiable {
    case mysql
    case postgres
    case sqlite
    case clickhouse

    var id: String { rawValue }

    // Forward-compatible decoding: a connections.json written by a newer build may
    // name an engine this build doesn't have. Falling back to .mysql keeps the rest
    // of the connection (and every other connection in the file) instead of throwing
    // and wiping the whole saved list. Encoding stays the plain raw value.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DatabaseEngine(rawValue: raw) ?? .mysql
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// True when the connection is a local file rather than a server.
    var isFileBased: Bool { self == .sqlite }

    /// True when the engine is reached through its own native protocol instead of
    /// a DuckDB scanner. Native connections browse and query, but cannot take
    /// part in cross-engine joins — they are outside DuckDB's catalog.
    var isNative: Bool { self == .clickhouse }

    /// The ways the app can reach this engine, in the order the connection form lists them.
    /// ClickHouse is reached over HTTP, so a Unix socket is not one of them; a SQLite
    /// connection is a file; the App Store build's sandbox refuses sockets.
    var connectionTypes: [ConnectionType] { connectionTypes(in: .current) }

    func connectionTypes(in distribution: Distribution) -> [ConnectionType] {
        let all: [ConnectionType]
        switch self {
        case .mysql, .postgres: all = [.tcpip, .ssh, .socket]
        case .clickhouse:       all = [.tcpip, .ssh]
        case .sqlite:           all = []
        }
        return distribution.offersSockets ? all : all.filter { $0 != .socket }
    }

    /// The socket path the connection form starts from: MySQL's usual socket file,
    /// PostgreSQL's usual socket directory.
    var defaultSocketPath: String {
        switch self {
        case .mysql:    return "/tmp/mysql.sock"
        case .postgres: return "/tmp"
        case .sqlite, .clickhouse: return ""
        }
    }

    var displayName: String {
        switch self {
        case .mysql:    return "MySQL"
        case .postgres: return "PostgreSQL"
        case .sqlite:   return "SQLite"
        case .clickhouse: return "ClickHouse"
        }
    }

    /// DuckDB extension providing the scanner for this engine.
    var extensionName: String {
        switch self {
        case .mysql:    return "mysql_scanner"
        case .postgres: return "postgres_scanner"
        case .sqlite:   return "sqlite_scanner"
        case .clickhouse: return ""   // native HTTP, no scanner
        }
    }

    /// Value for ATTACH's `TYPE` option.
    var attachType: String { extensionName }

    /// DSN key naming the initial database. MySQL and Postgres disagree, and
    /// passing the wrong one is a connection failure rather than a warning.
    var databaseDSNKey: String {
        switch self {
        case .mysql:    return "database"
        case .postgres: return "dbname"
        case .sqlite:   return ""   // a file path, not a DSN
        case .clickhouse: return ""  // native HTTP, no DSN
        }
    }

    var defaultPort: Int {
        switch self {
        case .mysql:    return 3306
        case .postgres: return 5432
        case .sqlite:   return 0    // no network endpoint
        case .clickhouse: return 8123   // the HTTP interface, not the native TCP port
        }
    }

    /// Quotes an identifier the way this engine's own SQL dialect expects.
    func identifier(_ s: String) -> String {
        switch self {
        case .mysql:    return SQLBuilder.mysqlIdent(s)
        case .postgres, .sqlite, .clickhouse: return SQLBuilder.duckIdent(s)   // all double-quote
        }
    }
}
