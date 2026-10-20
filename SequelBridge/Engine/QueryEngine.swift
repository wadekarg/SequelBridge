//
//  QueryEngine.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import Foundation
import os
@preconcurrency import DuckDB
import Darwin

// Disambiguate DuckDB.Connection from the app's Connection model
private typealias DBConnection = DuckDB.Connection

// duckdb_interrupt comes straight from the C API — duckdb-swift does not wrap
// it. It is thread-safe by design: it flags the running statement from any
// thread, and the query returns with an INTERRUPT error while the connection
// stays usable.
import Cduckdb

extension DuckDB.Connection {
    /// Best-effort interrupt of whatever this connection is executing.
    ///
    /// The raw connection handle is private to duckdb-swift, so it is read via
    /// reflection — the one place this app depends on the package's internals.
    /// QueryCancelTests exercises the whole path against a real long query, so a
    /// layout change in the package fails loudly there, and this returns false
    /// (cancel degrades to the old task-abandoning behaviour) rather than crash.
    @discardableResult
    nonisolated func sbInterrupt() -> Bool {
        for child in Mirror(reflecting: self).children where child.label == "ptr" {
            if let p = child.value as? UnsafeMutablePointer<duckdb_connection?> {
                duckdb_interrupt(p.pointee)
                return true
            }
        }
        return false
    }
}

/// Serializes all DuckDB connection calls so concurrent queries don't hang.
/// DuckDB's connection is not thread-safe — this actor ensures one query at a time.
private actor SerialConnection {
    private let conn: DBConnection

    init(_ conn: DBConnection) { self.conn = conn }

    // Check cancellation before running — lets cancelled tasks skip their queue slot
    // so a newly-visible panel doesn't wait for off-screen panels to finish.
    func query(_ sql: String) throws -> ResultSet {
        try Task.checkCancellation()
        try readyForStatement()
        return try conn.query(sql)
    }
    func execute(_ sql: String) throws {
        try Task.checkCancellation()
        try readyForStatement()
        try conn.execute(sql)
    }

    // MARK: - Streaming cursors
    //
    // A query runs as a DuckDB STREAMING result (vendor/DuckDB StreamingResult): the
    // pipeline produces one data chunk per fetch, on this actor (off the main thread),
    // so the first rows paint while the server is still sending and a large result is
    // never materialized inside DuckDB next to the app's own cells. Each open stream
    // gets its OWN cursor, keyed by a unique id. DuckDB allows one live streaming
    // result per connection — running anything else on it closes the stream — so
    // before another statement starts here, every open stream's remaining chunks are
    // fetched into its cursor's buffer and delivered from there: an earlier query
    // (another tab) still completes with its full result. A string DuckDB can't
    // prepare (several statements in one) falls back to a materialized result read
    // by row ranges, as before.

    private enum Source {
        case streaming(StreamingResult)
        case materialized(ResultSet, offset: Int)
    }
    private struct Cursor {
        var source: Source?             // nil once the query has produced everything
        var buffered: [ResultChunk] = []
        var bufferedNext = 0            // next buffered chunk to deliver
        var delivered = 0               // rows handed out so far
        let types: [DatabaseType]
    }
    private var cursors: [Int: Cursor] = [:]
    private var nextCursorId = 0

    struct StreamHead: Sendable { let columns: [String]; let types: [DatabaseType]; let id: Int }

    /// What one pull delivered: `chunk` is nil when nothing is left; `hasMore` is
    /// false once the query has produced everything; `delivered` counts all rows so far.
    struct Pulled: Sendable { let chunk: CellTable.Chunk?; let hasMore: Bool; let delivered: Int }

    /// Before any new statement on this connection: fetches what every open stream
    /// still has into its buffer, so the statement can't close them mid-result (a
    /// stream already in error — an interrupted query whose owner hasn't closed it
    /// yet — just ends there), and undoes a previous statement's pinned join order.
    private func readyForStatement() throws {
        for (id, var c) in cursors {
            guard case .streaming(let result)? = c.source else { continue }
            while let chunk = try? result.nextChunk() { c.buffered.append(chunk) }
            c.source = nil
            cursors[id] = c
        }
        if joinOrderPinned {
            joinOrderPinned = false
            try conn.execute("RESET disabled_optimizers")
        }
    }

    /// Whether the last statement opened with its join order pinned. The setting is
    /// undone by `readyForStatement`, right before the next statement — not when the
    /// stream opens, since any statement on the connection closes the live result.
    private var joinOrderPinned = false

    /// Opens `sql` as a streaming result. With `pinJoinOrder`, DuckDB's join-order
    /// and build/probe-side optimizers are off while the statement is planned, so a
    /// hash join probes with the table written first and builds on the second: for a
    /// cross-server join DuckDB has no row estimate for either passthrough subquery
    /// (a table function reports ~1 row) and would otherwise guess — and guess the
    /// big side onto the build side, where every row has to arrive before the first
    /// joined row comes out. The setting is scoped to this one statement.
    func openStream(_ sql: String, pinJoinOrder: Bool = false) throws -> StreamHead {
        try Task.checkCancellation()
        try readyForStatement()
        let id = nextCursorId; nextCursorId &+= 1
        let source: Source
        let n: Int
        let cols: [String]
        let types: [DatabaseType]
        if pinJoinOrder {
            try conn.execute("SET disabled_optimizers = 'join_order,build_side_probe_side'")
            joinOrderPinned = true
        }
        do {
            let result = try StreamingResult(prepared: PreparedStatement(connection: conn, query: sql))
            n = Int(result.columnCount)
            types = (0..<n).map { result.columnDataType(at: DBInt($0)) }
            cols  = (0..<n).map { result.columnName(at: DBInt($0)) }
            source = .streaming(result)
        } catch DatabaseError.preparedStatementFailedToInitialize(let reason)
                    where reason?.lowercased().contains("multiple statements") == true {
            let rs = try conn.query(sql)
            n = Int(rs.columnCount)
            types = (0..<n).map { rs[DBInt($0)].underlyingDatabaseType }
            cols  = (0..<n).map { rs.columnName(at: DBInt($0)) }
            source = .materialized(rs, offset: 0)
        }
        cursors[id] = Cursor(source: source, types: types)
        return StreamHead(columns: cols, types: types, id: id)
    }

    /// Up to `size` rows (whole data chunks, so a little more), as one cell chunk.
    /// With `probe`, one extra chunk is fetched ahead so `hasMore` is exact for a
    /// result that fits the first pull — the first paint then needs no "Loading…".
    func pull(_ size: Int, id: Int, probe: Bool = false) throws -> Pulled? {
        try Task.checkCancellation()
        guard var c = cursors[id] else { return nil }
        var pieces: [ResultChunk] = []
        var rows = 0
        var materialized: (rs: ResultSet, range: Range<Int>)? = nil
        func nextPiece() throws -> ResultChunk? {
            if c.bufferedNext < c.buffered.count {
                defer { c.bufferedNext += 1 }
                return c.buffered[c.bufferedNext]
            }
            guard case .streaming(let result)? = c.source else { return nil }
            let piece = try result.nextChunk()
            if piece == nil { c.source = nil }
            return piece
        }
        if case .materialized(let rs, let offset)? = c.source {
            let total = Int(rs.rowCount)
            let end = min(offset + size, total)
            if end > offset { materialized = (rs, offset..<end); rows = end - offset }
            c.source = end < total ? .materialized(rs, offset: end) : nil
        } else {
            while rows < size, let piece = try nextPiece() {
                pieces.append(piece); rows += piece.rowCount
            }
            if probe, rows > 0, case .streaming(let result)? = c.source {
                if let ahead = try result.nextChunk() { c.buffered.append(ahead) } else { c.source = nil }
            }
        }
        if c.bufferedNext == c.buffered.count { c.buffered.removeAll(); c.bufferedNext = 0 }
        let hasMore = c.source != nil || c.bufferedNext < c.buffered.count
        c.delivered += rows
        let delivered = c.delivered
        if hasMore { cursors[id] = c } else { cursors[id] = nil }   // drained → release
        let chunk: CellTable.Chunk?
        if let m = materialized {
            chunk = QueryEngine.cellChunk(materialized: m.rs, rows: m.range, columnCount: c.types.count)
        } else if rows > 0 {
            chunk = QueryEngine.cellChunk(pieces: pieces, columnCount: c.types.count)
        } else {
            chunk = nil
        }
        return Pulled(chunk: chunk, hasMore: hasMore, delivered: delivered)
    }

    /// Releases a cursor whose caller stopped pulling early (cancel, superseded query);
    /// destroying the streaming result ends the query's pipeline.
    func closeStream(_ id: Int) { cursors[id] = nil }

    /// Deliberately nonisolated: the whole point is to reach a connection whose
    /// actor is blocked inside a running query. duckdb_interrupt is thread-safe.
    nonisolated func interrupt() {
        let ok = conn.sbInterrupt()
        if !ok { print("[SerialConnection] interrupt: connection handle not found via reflection") }
    }

    /// True when the reflection path to the raw connection handle works.
    nonisolated var canInterrupt: Bool {
        Mirror(reflecting: conn).children.contains {
            $0.label == "ptr" && $0.value is UnsafeMutablePointer<duckdb_connection?>
        }
    }
}

@MainActor
final class QueryEngine {
    private let db: Database
    private let conn: DBConnection           // primary: ATTACH / DETACH / LOAD extension
    private let userSerial:    SerialConnection  // Query-tab queries
    private let contentSerial: SerialConnection  // Content browser — its own connection so browsing a table never blocks (or is blocked by) a Query-tab query
    private let metaSerial:    SerialConnection  // fast schema queries → duckdb_columns/constraints (in-memory, instant)
    private let sidebarSerial: SerialConnection  // slow info_schema.tables — isolated so it can't block metaSerial

    /// Which connection a user query runs on. Separate connections run in parallel
    /// (DuckDB connections are independent and share the ATTACH catalog), so a slow
    /// Query-tab query no longer stalls the Content browser and vice versa.
    enum Lane: Sendable { case user, content }
    private func serial(_ lane: Lane) -> SerialConnection { lane == .content ? contentSerial : userSerial }

    private var tableMetaCache: [String: [String]] = [:]  // "alias.db.table" → raw row
    private var sshTunnels: [String: SSHTunnel] = [:]
    /// Engine backing each attached alias, so metadata and DDL take the right route.
    var engines: [String: DatabaseEngine] = [:]
    /// The database each alias is ATTACHed with (its DSN default). The passthrough
    /// needs this to be non-empty and to match the selected database; it's updated when
    /// a connection is re-attached to adopt the sidebar-selected database.
    private var attachedDSN: [String: String] = [:]
    /// File backing each attached SQLite alias; sqlite_scan needs the path.
    private var sqlitePaths: [String: String] = [:]     // alias → the SQLite file's path
    private var postgresConfigs: [String: PostgresClient.Config] = [:]   // alias → PostgreSQL's own client
    /// How long a change to a SQLite file waits for a lock another connection holds.
    var sqliteBusyTimeout: TimeInterval = 5
    /// Native-client TCP params per MySQL alias (effective host/port after any SSH
    /// tunnel). Used only for statements mysql_scanner can't prepare — EXPLAIN and
    /// exact SHOW CREATE TABLE. nil for socket connections (native client is TCP-only).
    private var mysqlConfigs: [String: MySQLClient.Config] = [:]

    /// Aliases opened in read-only / safe mode. Any write to one of these is refused.
    private var readOnlyAliases: Set<String> = []

    /// True if `alias` was attached from a read-only connection (safe mode).
    func isReadOnly(_ alias: String) -> Bool { readOnlyAliases.contains(alias) }

    /// Throw if `alias` is read-only — the single guard every write path calls.
    /// Not private: the ClickHouse write path lives in a separate extension file.
    func ensureWritable(_ alias: String) throws {
        if readOnlyAliases.contains(alias) { throw SequelBridgeError.readOnly(alias) }
    }

    /// Refuses `sql` on a read-only connection unless it only reads (EXPLAIN ANALYZE of a
    /// write runs the write). The server's own read-only session is the backstop; this
    /// says why in the app's words.
    func ensureReads(_ sql: String, alias: String) throws {
        if readOnlyAliases.contains(alias), !SQLBuilder.isReadOnly(sql) { throw SequelBridgeError.readOnly(alias) }
    }

    /// Runs a write the panels build (a Content-tab cell edit, insert or delete) against
    /// `alias`, refused first on a read-only connection. `query` has no such check, so a
    /// write must not go through it directly.
    func executeWrite(_ sql: String, alias: String, lane: Lane = .content) async throws {
        try ensureWritable(alias)
        _ = try await query(sql, lane: lane)
    }

    /// The database `alias` is currently attached with (empty if none / detached).
    func attachedDatabase(_ alias: String) -> String { attachedDSN[alias] ?? "" }
    /// Records what `attachedDatabase` answers for an alias attached outside the
    /// DSN path (a native connection).
    func setAttachedDatabase(_ database: String, for alias: String) { attachedDSN[alias] = database }

    init() throws {
        let config = Database.Configuration()
        try? config.setValue("true", forKey: "allow_unsigned_extensions")
        db = try Database(store: .inMemory, configuration: config)
        conn = try db.connect()
        let contentConn = try db.connect()
        let metaConn    = try db.connect()
        let sidebarConn = try db.connect()
        userSerial    = SerialConnection(conn)
        contentSerial = SerialConnection(contentConn)
        metaSerial    = SerialConnection(metaConn)
        sidebarSerial = SerialConnection(sidebarConn)

        // DuckDB defaults its TimeZone to the host OS. mysql_scanner surfaces MySQL
        // TIMESTAMP columns as timestamptz, so a naive server value was being read as
        // local time and re-rendered — shifting every TIMESTAMP by the viewer's UTC
        // offset, and by a different amount either side of a DST boundary. Two people
        // reading the same row saw different times.
        //
        // Pinning UTC makes the reading deterministic, and exact for the common case of
        // a server running UTC. DATETIME, DATE and TIME are naive and unaffected.
        for c in [conn, contentConn, metaConn, sidebarConn] {
            try? c.execute("SET TimeZone='UTC'")
        }
    }

    // MARK: - MySQL Extension Loader

    /// Downloads, decompresses, ad-hoc signs, and loads a DuckDB scanner extension.
    /// Must be called before the corresponding ATTACH. Safe to call multiple times.
    func ensureExtensionLoaded(_ name: String) async throws {
        // All access to the primary connection must go through userSerial — the
        // same actor user queries run on — or a LOAD/check here can execute on the
        // main thread while a user query runs conn.query() on the actor's thread,
        // and DuckDB's connection is not thread-safe (heap corruption / crash).
        if let check = try? await userSerial.query(
            "SELECT extension_name FROM duckdb_extensions() WHERE extension_name=\(SQLBuilder.literal(name)) AND loaded=true"),
           check.rowCount > 0 {
            Log.engine.info("\(name, privacy: .public) already loaded")
            return
        }

        let extPath = try await Self.prepareExtension(named: name)
        try await userSerial.execute("LOAD '\(extPath)'")
        Log.engine.info("\(name, privacy: .public) loaded from \(extPath, privacy: .public)")
    }

    func ensureMySQLExtensionLoaded() async throws {
        try await ensureExtensionLoaded("mysql_scanner")
    }

    /// DuckDB version the app links (vendor/DuckDB, via scripts/fetch-duckdb.sh). DuckDB
    /// extensions are built per exact version — the download URL AND the cache path are
    /// scoped by it, so bumping the vendored DuckDB here auto-invalidates stale cached
    /// extensions and fetches the matching builds. Keep in lockstep with the libs.
    nonisolated static let duckDBVersion = "v1.5.6"

    /// The DuckDB platform this process loads: an Apple Silicon Mac runs osx_arm64
    /// natively and osx_amd64 under Rosetta.
    nonisolated static var extensionPlatform: String {
        #if arch(arm64)
        "osx_arm64"
        #else
        "osx_amd64"
        #endif
    }

    /// Where a download of `name` goes: a folder per CPU, since one Mac can run the app
    /// natively and under Rosetta, which need different builds of a scanner.
    nonisolated static func extensionFile(named name: String, in versionDir: URL) -> URL {
        versionDir.appendingPathComponent(extensionPlatform, isDirectory: true)
            .appendingPathComponent("\(name).duckdb_extension")
    }

    /// A cached build of `name` this process can load: the one in this CPU's folder, else
    /// one from before the cache was split by CPU, if its Mach-O header is this CPU's.
    nonisolated static func cachedExtension(named name: String, in versionDir: URL) -> URL? {
        let scoped = extensionFile(named: name, in: versionDir)
        if FileManager.default.fileExists(atPath: scoped.path) { return scoped }
        let unsplit = versionDir.appendingPathComponent("\(name).duckdb_extension")
        return isLibraryForThisCPU(unsplit) ? unsplit : nil
    }

    /// Whether `url` starts with a 64-bit Mach-O header for this process's CPU.
    nonisolated static func isLibraryForThisCPU(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return false }
        let b = [UInt8](head)
        func word(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
        guard word(0) == 0xFEED_FACF else { return false }                                   // MH_MAGIC_64
        return word(4) == (extensionPlatform == "osx_arm64" ? 0x0100_000C : 0x0100_0007)     // CPU_TYPE_ARM64 / X86_64
    }

    /// Downloads (if needed) the extension binary, decompresses it, and ad-hoc signs it.
    /// Returns the path to the ready-to-load `.duckdb_extension` file.
    nonisolated private static func prepareExtension(named name: String) async throws -> String {
        // Version-scoped cache dir so a DuckDB bump never loads a stale, incompatible build;
        // inside it, one folder per CPU.
        let versionDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SequelBridge/duckdb/\(duckDBVersion)", isDirectory: true)
        if let cached = cachedExtension(named: name, in: versionDir) {
            Log.engine.info("Using cached extension at \(cached.path, privacy: .public)")
            return cached.path
        }
        let extFile = extensionFile(named: name, in: versionDir)
        let cacheDir = extFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let platform = extensionPlatform

        let urlStr = "https://extensions.duckdb.org/\(duckDBVersion)/\(platform)/\(name).duckdb_extension.gz"
        guard let url = URL(string: urlStr) else {
            throw SequelBridgeError.attachFailed("Invalid extension URL")
        }

        Log.engine.info("Downloading \(name, privacy: .public) from \(urlStr, privacy: .public)…")
        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SequelBridgeError.attachFailed("Extension download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }

        // Decompress to a UNIQUE temp file: concurrent first-launch / CI downloads must
        // not collide on a shared name (a fixed name let two processes gunzip into the
        // same file and corrupt it). Then atomically place it; if another process won the
        // race and already created extFile, keep theirs.
        let decompressed = cacheDir.appendingPathComponent("\(name)-\(UUID().uuidString).tmp")
        try Self.gunzip(input: tmpURL, output: decompressed)
        try? FileManager.default.removeItem(at: tmpURL)
        if FileManager.default.fileExists(atPath: extFile.path) {
            try? FileManager.default.removeItem(at: decompressed)
            Log.engine.info("\(name, privacy: .public) already placed by a concurrent download")
            return extFile.path
        }
        do {
            try FileManager.default.moveItem(at: decompressed, to: extFile)
        } catch {
            try? FileManager.default.removeItem(at: decompressed)
            if FileManager.default.fileExists(atPath: extFile.path) { return extFile.path }
            throw error
        }

        // Ad-hoc sign only required on Apple Silicon; on Intel, disable-library-validation suffices
        #if arch(arm64)
        try? Self.adhocSign(extFile)
        #endif
        Log.engine.info("Extension ready at \(extFile.path, privacy: .public)")
        return extFile.path
    }

    nonisolated static func gunzip(input: URL, output: URL) throws {
        // The decompressed extension is ~90MB. Piping it to the parent and only
        // draining the pipe *after* waitUntilExit() deadlocks: gunzip fills the
        // 64KB pipe buffer, blocks on write, and never exits — so the wait never
        // returns. Writing straight to the destination file removes the pipe
        // entirely, and keeps the payload out of memory.
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw SequelBridgeError.attachFailed("Could not create \(output.lastPathComponent)")
        }
        let sink = try FileHandle(forWritingTo: output)
        defer { try? sink.close() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", input.path]
        p.standardOutput = sink
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run()

        // stderr stays a pipe: it is small, and reading to EOF completes when the
        // child exits. Read before waiting so a chatty failure cannot block either.
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: output)
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw SequelBridgeError.attachFailed("gunzip failed: \(msg)")
        }
    }

    nonisolated private static func adhocSign(_ url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-s", "-", "-f", url.path]
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SequelBridgeError.attachFailed("codesign failed: \(msg)")
        }
        Log.engine.info("Ad-hoc signed \(url.lastPathComponent, privacy: .public)")
    }

    // MARK: - Connection management

    /// The scanner DSN for a connection. A key with an empty value must be
    /// omitted entirely — mysql_scanner rejects a dangling "password=" as a
    /// malformed pair, which broke every passwordless server (TiDB's default
    /// root account, development boxes).
    nonisolated static func buildDSN(for c: Connection, password: String, socket: String? = nil) -> String {
        if c.engine.isFileBased { return c.database }
        var parts: [String] = []
        if let socket, c.engine == .postgres {
            // libpq takes the socket's directory as the host and opens
            // <directory>/.s.PGSQL.<port> itself; the path may name either.
            let s = postgresSocket(socket, defaultPort: c.port)
            parts.append("host=\(sqlLiteralEscape(s.directory))")
            parts.append("port=\(s.port)")
        } else if let socket {
            parts.append("socket=\(sqlLiteralEscape(socket))")
        } else {
            parts.append("host=\(sqlLiteralEscape(c.host))")
            parts.append("port=\(c.port)")
        }
        if !c.username.isEmpty { parts.append("user=\(sqlLiteralEscape(c.username))") }
        if !password.isEmpty   { parts.append("password=\(sqlLiteralEscape(password))") }
        if !c.database.isEmpty {
            // MySQL calls the initial database "database"; Postgres calls it "dbname".
            parts.append("\(c.engine.databaseDSNKey)=\(sqlLiteralEscape(c.database))")
        }
        // "Use SSL" requires an encrypted session. Without it each driver still encrypts
        // when the server offers TLS (MySQL ssl_mode=preferred, libpq sslmode=prefer).
        if c.useSSL {
            switch c.engine {
            case .mysql:    parts.append("ssl_mode=required")
            case .postgres: parts.append("sslmode=require")
            default:        break
            }
        }
        return parts.joined(separator: " ")
    }

    /// A PostgreSQL socket given as a directory (`/tmp`) or as the socket file itself
    /// (`/tmp/.s.PGSQL.5432`), as libpq wants it: the directory, and the port the file
    /// name carries (else the connection's port).
    nonisolated static func postgresSocket(_ path: String, defaultPort: Int) -> (directory: String, port: Int) {
        let name = (path as NSString).lastPathComponent
        let prefix = ".s.PGSQL."
        guard name.hasPrefix(prefix), let port = Int(name.dropFirst(prefix.count)) else {
            return (path, defaultPort)
        }
        return ((path as NSString).deletingLastPathComponent, port)
    }

    /// Opens an SSH tunnel for `c` and keeps it under the connection's alias until
    /// `stopTunnel` (detach). Returns the local port that now forwards to c.host:c.port.
    func startTunnel(for c: Connection) async throws -> Int {
        let tunnel = SSHTunnel()
        try await tunnel.start(conn: c)
        sshTunnels[c.alias] = tunnel
        return tunnel.localPort
    }

    func stopTunnel(_ alias: String) {
        sshTunnels[alias]?.stop()
        sshTunnels.removeValue(forKey: alias)
    }

    func attach(_ c: Connection, password: String) async throws {
        // Track safe mode for every engine, before the per-engine early returns below.
        if c.readOnly { readOnlyAliases.insert(c.alias) } else { readOnlyAliases.remove(c.alias) }
        // SQLite is a file: no DSN, no credentials, and the path is the database.
        if c.engine.isFileBased {
            try await attachSQLite(c)
            return
        }
        // ClickHouse is native HTTP — no scanner, no ATTACH.
        if c.engine.isNative {
            try await attachClickHouse(c, password: password)
            return
        }
        var dsnParts: String
        // Capture the effective (post-tunnel) endpoint so the native MySQL client can
        // run the few statements mysql_scanner can't prepare (EXPLAIN, SHOW CREATE TABLE).
        var nativeHost = c.host
        var nativePort = c.port
        var nativeSocket: String? = nil
        switch c.connectionType {
        case .tcpip:
            dsnParts = Self.buildDSN(for: c, password: password)
        case .socket:
            dsnParts = Self.buildDSN(for: c, password: password, socket: c.socketPath)
            nativeSocket = c.socketPath
        case .ssh:
            var tunneled = c
            tunneled.host = "127.0.0.1"
            tunneled.port = try await startTunnel(for: c)
            nativeHost = tunneled.host
            nativePort = tunneled.port
            dsnParts = Self.buildDSN(for: tunneled, password: password)
        }
        do {
            // Ensure this engine's scanner extension is loaded (downloads on first run)
            try await ensureExtensionLoaded(c.engine.extensionName)
            engines[c.alias] = c.engine
            attachedDSN[c.alias] = c.database
            // Remember the endpoint for the native MySQL client (EXPLAIN / SHOW CREATE TABLE).
            if c.engine == .mysql {
                mysqlConfigs[c.alias] = MySQLClient.Config(
                    host: nativeHost, port: nativePort, user: c.username,
                    password: password, database: c.database, useTLS: c.useSSL,
                    socketPath: nativeSocket, readOnly: c.readOnly)
            }
            // And for PostgreSQL's own client (EXPLAIN, SHOW).
            if c.engine == .postgres {
                let socket = nativeSocket.map { Self.postgresSocket($0, defaultPort: c.port) }
                postgresConfigs[c.alias] = PostgresClient.Config(
                    host: nativeHost, port: socket?.port ?? nativePort, user: c.username,
                    password: password, database: c.database, useTLS: c.useSSL,
                    socketDirectory: socket?.directory, readOnly: c.readOnly)
            }

            let sql = "ATTACH '\(dsnParts)' AS \(sqlIdentifierQuote(c.alias)) \(Self.attachOptions(c))"
            Log.engine.info("ATTACH alias=\(c.alias, privacy: .public) host=\(c.host) type=\(c.connectionType.rawValue, privacy: .public)")
            try await userSerial.execute(sql)
            Log.engine.info("ATTACH succeeded: \(c.alias, privacy: .public)")
            // Apply the connection's saved default database so unqualified table
            // names resolve immediately, without the user re-picking it in the
            // sidebar. ATTACH exposes every schema under the alias, so the DSN's
            // database= alone does not set DuckDB's active catalog+schema.
            if !c.database.isEmpty {
                await setDefaultContextAwaited(alias: c.alias, database: c.database)
            }
        } catch {
            // Roll back partial state: if the SSH tunnel started but a later step
            // (extension load / ATTACH) failed, the tunnel would otherwise leak.
            stopTunnel(c.alias)
            mysqlConfigs.removeValue(forKey: c.alias)
            postgresConfigs.removeValue(forKey: c.alias)
            engines.removeValue(forKey: c.alias)
            readOnlyAliases.remove(c.alias)   // don't leave safe-mode state for a failed attach
            let reason = Self.connectionError(Self.extractReason(from: error), password: password)
            let friendly = reason.isEmpty || reason.caseInsensitiveCompare("connection query failed") == .orderedSame
                ? "Could not connect to \(c.engine.displayName) server at \(c.host):\(c.port). Check the host, port, and credentials."
                : reason
            Log.engine.error("ATTACH failed: \(friendly, privacy: .public)")
            throw SequelBridgeError.attachFailed(friendly)
        }
    }

    /// ATTACH's options. A read-only connection is attached READ_ONLY, so DuckDB itself
    /// refuses a write to it on every path (its catalog, mysql_execute), and PostgreSQL's
    /// statements run in read-only transactions, where the server refuses one too.
    nonisolated static func attachOptions(_ c: Connection) -> String {
        c.readOnly ? "(TYPE \(c.engine.attachType), READ_ONLY)" : "(TYPE \(c.engine.attachType))"
    }

    /// ATTACHes a local SQLite file under the connection's alias; the file must exist.
    private func attachSQLite(_ c: Connection) async throws {
        let path = (c.database as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw SequelBridgeError.attachFailed("No SQLite database at \(path)")
        }
        try await ensureExtensionLoaded(c.engine.extensionName)
        do {
            try await userSerial.execute("ATTACH \(SQLBuilder.literal(path)) AS \(sqlIdentifierQuote(c.alias)) \(Self.attachOptions(c))")
        } catch {
            throw SequelBridgeError.attachFailed(Self.extractReason(from: error))
        }
        engines[c.alias] = c.engine
        attachedDSN[c.alias] = c.database
        sqlitePaths[c.alias] = path
    }


    /// Aborts whatever the user connection is currently executing. The query
    /// comes back as an error; the connection survives.
    func interruptUserQuery() {
        userSerial.interrupt()
    }

    /// Exposed for tests: whether real interruption is available at runtime.
    var interruptAvailable: Bool { userSerial.canInterrupt }

    /// Runs a statement that returns no result set against whichever engine backs
    /// the alias.
    func executeDDL(alias: String, sql: String) async throws {
        switch engine(for: alias) {
        case .mysql:    try await mysqlExecute(alias: alias, sql: sql)
        case .postgres: try await postgresExecute(alias: alias, sql: sql)
        case .sqlite:   try await sqliteExecute(alias: alias, sql: sql)
        case .clickhouse: try await clickhouseExecute(alias: alias, sql: sql)
        }
    }

    /// Runs a statement in SQLite itself, in SQLite's own SQL, on the file behind `alias`
    /// (see SQLiteTool for why not through DuckDB). DuckDB sees the change at once.
    func sqliteExecute(alias: String, sql: String) async throws {
        try ensureWritable(alias)
        guard let file = sqlitePaths[alias] else { throw SequelBridgeError.attachFailed("No SQLite file is open as \(alias).") }
        let start = Date()
        do {
            try await SQLiteTool.run(sql, file: file, busyTimeout: sqliteBusyTimeout)
            logStatement(sql, nil, nil, Date().timeIntervalSince(start))
        } catch {
            let reason = Self.extractReason(from: error)
            logStatement(sql, nil, reason, Date().timeIntervalSince(start))
            throw SequelBridgeError.attachFailed(reason)
        }
    }

    /// postgres_execute() is the postgres_scanner counterpart to mysql_execute().
    /// Unlike mysql_query(), a rejected statement here throws without invalidating
    /// the connection.
    func postgresExecute(alias: String, sql: String) async throws {
        try ensureWritable(alias)
        let call = "CALL postgres_execute(\(SQLBuilder.literal(alias)), \(SQLBuilder.literal(sql)))"
        let start = Date()
        do {
            try await userSerial.execute(call)
            logStatement(sql, nil, nil, Date().timeIntervalSince(start))
        } catch {
            let reason = Self.extractReason(from: error)
            logStatement(sql, nil, reason, Date().timeIntervalSince(start))
            throw SequelBridgeError.attachFailed(reason)
        }
    }

    /// Runs `sql` on `alias`'s MySQL server as typed, as Sequel Ace does, and returns the
    /// rows it changed: nil for a statement MySQL doesn't count (OPTIMIZE TABLE). The
    /// statement runs in a transaction of its own, which keeps one server connection for
    /// it and the ROW_COUNT() after it; inside a transaction begun in the Query tab it
    /// runs in that one instead, and waits for its COMMIT or ROLLBACK.
    func runAsTyped(alias: String, sql: String) async throws -> Int? {
        // (A nested BEGIN can't probe for the Query tab's transaction: in DuckDB a failed
        // statement aborts the transaction it ran in.)
        try ensureWritable(alias)
        if engine(for: alias) == .postgres {
            // postgres_execute reports no row count, and a counting data-modifying CTE
            // can't go through postgres_query either: it wraps the query in COPY.
            try await postgresExecute(alias: alias, sql: sql)
            return nil
        }
        let start = Date()
        let ownTransaction = !queryTabTransaction
        do {
            // The transaction and the count are the app's own statements: the Console shows them as such.
            if ownTransaction { try await userSerial.execute("BEGIN TRANSACTION"); logStatement("BEGIN TRANSACTION", nil, nil, 0, appsOwn: true) }
            try await userSerial.execute("CALL mysql_execute(\(SQLBuilder.literal(alias)), \(SQLBuilder.literal(sql)))")
            let counted = try await userSerial.query("SELECT * FROM mysql_query(\(SQLBuilder.literal(alias)), 'SELECT ROW_COUNT()')")
            logStatement("SELECT ROW_COUNT()", 1, nil, 0, appsOwn: true)
            if ownTransaction { try await userSerial.execute("COMMIT"); logStatement("COMMIT", nil, nil, 0, appsOwn: true) }
            // The scanner caches the server's catalog: a table made a moment ago would be
            // invisible to the next DuckDB-level statement.
            try? await userSerial.execute("CALL mysql_clear_cache()")
            let rows = counted.rowCount > 0 ? Self.extractColumn(counted, colIndex: 0, rowRange: 0..<1).first ?? nil : nil
            let changed = rows.flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil }
            logStatement(sql, changed, nil, Date().timeIntervalSince(start))
            return changed
        } catch {
            if ownTransaction { try? await userSerial.execute("ROLLBACK"); logStatement("ROLLBACK", nil, nil, 0, appsOwn: true) }
            let reason = Self.extractReason(from: error)
            logStatement(sql, nil, reason, Date().timeIntervalSince(start))
            throw SequelBridgeError.attachFailed(reason)
        }
    }

    /// Whether a transaction begun in the Query tab (its BEGIN runs in DuckDB, on the user
    /// lane) is open: a statement run as typed joins it instead of opening its own.
    private var queryTabTransaction = false

    /// Follows BEGIN, COMMIT and ROLLBACK on the user lane. An end always ends it, even one
    /// that fails (DuckDB rolls back a COMMIT it can't make); a begin counts once it ran.
    private func noteTransaction(_ sql: String, lane: Lane, succeeded: Bool) {
        guard lane == .user, let begins = QueryEffects.transactionChange(sql) else { return }
        if !begins { queryTabTransaction = false } else if succeeded { queryTabTransaction = true }
    }

    func mysqlExecute(alias: String, sql: String) async throws {
        try ensureWritable(alias)
        // mysql_execute() is the mysql_scanner entry point for statements that
        // return no rows. The mysql_query() *table* function must bind at least
        // one output column, so DDL routed through it fails — and DuckDB raises
        // that as a FATAL error which invalidates the whole database handle.
        let call = "CALL mysql_execute(\(SQLBuilder.literal(alias)), \(SQLBuilder.literal(sql)))"
        let start = Date()
        do {
            try await userSerial.execute(call)
            // The scanner caches the remote catalog; without this, a table created
            // a moment ago is invisible to the very next DuckDB-level statement.
            // Observed on TiDB, cheap everywhere.
            try? await userSerial.execute("CALL mysql_clear_cache()")
            logStatement(sql, nil, nil, Date().timeIntervalSince(start))
        } catch {
            let reason = Self.extractReason(from: error)
            logStatement(sql, nil, reason, Date().timeIntervalSince(start))
            throw SequelBridgeError.attachFailed(reason)
        }
    }

    func detach(_ alias: String) async throws {
        if engines[alias] == .clickhouse {
            clickhouseClients[alias] = nil
            engines[alias] = nil
            readOnlyAliases.remove(alias)
            stopTunnel(alias)
            return
        }
        // Release local resources even if the remote DETACH throws (e.g. the alias
        // was never attached) — otherwise a failed DETACH leaks the SSH tunnel.
        defer {
            tableMetaCache = tableMetaCache.filter { !$0.key.hasPrefix("\(alias).") }
            activeContexts.removeValue(forKey: alias)
            engines.removeValue(forKey: alias)
            attachedDSN.removeValue(forKey: alias)
            mysqlConfigs.removeValue(forKey: alias)
            postgresConfigs.removeValue(forKey: alias)
            readOnlyAliases.remove(alias)
            stopTunnel(alias)
        }
        // DuckDB refuses to DETACH the *active* database. attach() runs `USE
        // "alias"."db"`, so the alias being detached is usually the default — and
        // the DETACH then fails ("Connection query failed"), leaving the alias
        // attached. That leak is why reconnecting to the same server errored. Switch
        // the default back to the in-memory catalog first so DETACH always applies.
        try? await userSerial.execute("USE memory")
        // Serialized with user queries — DETACH on the main thread while a query
        // runs on the actor's thread would use the non-thread-safe handle twice.
        do {
            try await userSerial.execute("DETACH \(sqlIdentifierQuote(alias))")
        } catch {
            // When the database the alias is attached on was dropped on the server, every
            // statement on the user connection fails with "Unknown database", USE memory
            // too, so the alias stays its default and DETACH refuses. Detach it from the
            // metadata connection, whose default is the in-memory catalog, then move the
            // user connection off the alias.
            try await metaSerial.execute("DETACH \(sqlIdentifierQuote(alias))")
            try? await userSerial.execute("USE memory")
        }
    }

    // MARK: - Error extraction

    /// True when an error is just task cancellation (a superseded load when the user
    /// switches tab/mode/table, or a cancelled HTTP request) — never shown to the user.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let u = error as? URLError, u.code == .cancelled { return true }
        return false
    }

    /// Extracts the human-readable reason from a DuckDB DatabaseError so the user
    /// sees "Access denied for user 'root'" instead of "DatabaseError error 4".
    /// A driver's error as the app shows it: the driver's own reason without the connection
    /// string both drivers wrap it in, and never a password. MySQL says `Failed to connect
    /// to MySQL database with parameters "<dsn>": <reason>`, PostgreSQL `Unable to connect
    /// to Postgres at "<dsn>": <reason>`, and the DSN holds the password. `password`, the
    /// one just used, is hidden wherever else it appears; any `password=`/`passwd=` value too.
    nonisolated static func connectionError(_ message: String, password: String) -> String {
        var s = message
        if let r = s.range(of: #"(IO Error: )?(Failed to connect to MySQL database with parameters|Unable to connect to Postgres at) "[^"]*": "#,
                           options: .regularExpression) {
            s.removeSubrange(r)
        }
        if password.count >= 3 {      // a shorter one would garble the message more than it hides
            for form in Set([password, sqlLiteralEscape(password)]) {
                s = s.replacingOccurrences(of: form, with: "•••")
            }
        }
        s = s.replacingOccurrences(of: #"(?i)\b(password|passwd)=\S*"#, with: "$1=•••", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What an error says, for the user. Passwords are hidden (see connectionError).
    static func extractReason(from error: Error) -> String {
        connectionError(rawReason(from: error), password: "")
    }

    private static func rawReason(from error: Error) -> String {
        if let dbErr = error as? DatabaseError {
            switch dbErr {
            case .connectionQueryError(let reason):              return reason ?? "Connection query failed"
            case .databaseFailedToInitialize(let reason):        return reason ?? "Database failed to initialize"
            case .preparedStatementQueryError(let reason):       return reason ?? "Query error"
            case .preparedStatementFailedToInitialize(let r):    return r ?? "Failed to prepare statement"
            case .preparedStatementFailedToBindParameter(let r): return r ?? "Failed to bind parameter"
            case .appenderFailedToAppendItem(let reason):        return reason ?? "Append failed"
            case .appenderFailedToEndRow(let reason):            return reason ?? "End row failed"
            case .appenderFailedToFlush(let reason):             return reason ?? "Flush failed"
            case .appenderFailedToInitialize(let reason):        return reason ?? "Appender init failed"
            case .connectionFailedToInitialize:                  return "Failed to initialise connection"
            case .configurationFailedToSetFlag:                  return "Failed to set configuration flag"
            // Any other DatabaseError case: show the enum's own description (case name +
            // associated reason) rather than the opaque "DatabaseError error N", so the
            // real DuckDB/server message reaches the user.
            default:                                             return "\(dbErr)"
            }
        }
        return error.localizedDescription
    }

    // MARK: - DuckDB type name helper

    private static func duckDBTypeName(_ type: DatabaseType) -> String {
        switch type {
        case .varchar:        return "VARCHAR"
        case .boolean:        return "BOOLEAN"
        case .tinyint:        return "TINYINT"
        case .smallint:       return "SMALLINT"
        case .integer:        return "INT"
        case .bigint:         return "BIGINT"
        case .hugeint:        return "HUGEINT"
        case .utinyint:       return "UTINYINT"
        case .usmallint:      return "USMALLINT"
        case .uinteger:       return "UINT"
        case .ubigint:        return "UBIGINT"
        case .float:          return "FLOAT"
        case .double:         return "DOUBLE"
        case .decimal:        return "DECIMAL"
        case .date:           return "DATE"
        case .time, .timeTz:  return "TIME"
        case .timestamp, .timestampS, .timestampMS, .timestampNS, .timestampTz: return "DATETIME"
        case .blob:           return "BLOB"
        case .uuid:           return "UUID"
        case .interval:       return "INTERVAL"
        case .enum:           return "ENUM"
        default:              return "TEXT"
        }
    }

    // MARK: - SQL escaping helpers

    /// Escapes a value for use inside a single-quoted SQL string literal.
    nonisolated private static func sqlLiteralEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    /// Wraps an identifier in double-quotes, escaping internal double-quotes.
    private func sqlIdentifierQuote(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Querying

    /// Sets the default catalog+schema so unqualified table names resolve correctly.
    /// Call this when the user selects a database in the sidebar.
    private var activeContexts: [String: String] = [:]  // alias → last-set database

    /// The database currently set as the default context for `alias`, or nil if
    /// none has been applied yet. Read-only; exposed so tests can verify that the
    /// connection's saved default database is applied on connect.
    func activeDatabase(for alias: String) -> String? { activeContexts[alias] }

    /// Awaitable version — call this from inside a Task so the USE completes before
    /// the subsequent query runs. The non-async wrapper below is kept for sidebar use.
    func setDefaultContextAwaited(alias: String, database: String) async {
        guard !alias.isEmpty, !database.isEmpty else { return }
        guard activeContexts[alias] != database else { return }
        do {
            try await userSerial.execute("USE \(sqlIdentifierQuote(alias)).\(sqlIdentifierQuote(database))")
            // Record the context only AFTER a successful USE. Recording it up front
            // (the old behaviour) meant a failed USE was swallowed yet the guard above
            // then skipped every retry, silently leaving unqualified names unresolved.
            activeContexts[alias] = database
            tableMetaCache = tableMetaCache.filter { !$0.key.hasPrefix("\(alias).") }
        } catch {
            Log.engine.error("USE \(alias, privacy: .public).\(database, privacy: .public) failed: \(Self.extractReason(from: error), privacy: .public)")
        }
    }

    /// Fire-and-forget variant used by the sidebar database selector (no need to await).
    func setDefaultContext(alias: String, database: String) {
        Task { await setDefaultContextAwaited(alias: alias, database: database) }
    }

    /// Called for every user-initiated statement — queries, DML and DDL — with the
    /// SQL, affected/returned row count, error text, and duration. The workspace
    /// points this at the console. Metadata lookups stay silent; logging every
    /// SHOW behind a panel refresh would bury the statements the user actually ran.
    var onStatement: ((String, Int?, String?, TimeInterval) -> Void)?
    /// The Console's hook for the statements the app builds or reads on its own: an edit,
    /// a page of rows, the tables and columns it lists. `onStatement` gets the ones typed
    /// in the Query tab (StatementSource.typedByYou); without this hook it gets them all.
    var onAppStatement: ((String, Int?, String?, TimeInterval) -> Void)?

    /// Sends a statement to the Console, as yours inside a Query-tab run, else as the
    /// app's; `appsOwn` marks the app's own reads even during one of your runs.
    func logStatement(_ sql: String, _ rows: Int?, _ error: String?, _ duration: TimeInterval,
                      typed: Bool = StatementSource.typedByYou, appsOwn: Bool = false) {
        if typed && !appsOwn { onStatement?(sql, rows, error, duration) }
        else { (onAppStatement ?? onStatement)?(sql, rows, error, duration) }
    }

    /// Runs a query and returns the COMPLETE result. Extraction happens on the DB
    /// actor (off the main thread), in chunks. Used by internal callers and paged
    /// browsing; the Query tab uses the streaming API below for progressive display.
    ///
    /// `logSQL` is what the console records: when `sql` is a passthrough wrapper
    /// (`SELECT * FROM mysql_query('alias', '…')`), the caller passes the user's own
    /// statement so the console shows that, not the wrapper.
    func query(_ sql: String, logSQL: String? = nil, lane: Lane = .user) async throws -> QueryResult {
        let start = Date()
        let logged = logSQL ?? sql
        let s = serial(lane)
        let head: SerialConnection.StreamHead
        do {
            head = try await s.openStream(sql)
        } catch {
            noteTransaction(sql, lane: lane, succeeded: false)
            logStatement(logged, nil, Self.extractReason(from: error), Date().timeIntervalSince(start))
            throw error
        }
        noteTransaction(sql, lane: lane, succeeded: true)
        var cells = CellTable(columnCount: head.columns.count)
        do {
            while let pulled = try await s.pull(65_536, id: head.id) {
                if let chunk = pulled.chunk { cells.append(chunk) }
                if !pulled.hasMore { break }
            }
        } catch {
            await s.closeStream(head.id)   // release the cursor on cancel/error
            logStatement(logged, nil, Self.extractReason(from: error), Date().timeIntervalSince(start))
            throw error
        }
        var result = QueryResult(columns: head.columns, cells: cells,
                                 executionTime: Date().timeIntervalSince(start))
        result.columnTypes = head.types.map { Self.duckDBTypeName($0) }
        result.totalRowCount = cells.rowCount
        logStatement(logged, cells.rowCount, nil, result.executionTime)
        return result
    }

    // MARK: - Streaming query (progressive display of large results, no row cap)

    /// Handle to an in-flight streaming query. Pass to `pullMore` for later chunks.
    /// Carries its own cursor id and lane, so streams on the same connection are
    /// independent and pulls go to the right connection. `hasMore` says whether
    /// anything is left after the first chunk; the total is only known at the end.
    struct QueryStream: Sendable { let id: Int; let lane: Lane; let hasMore: Bool }

    /// Streams still being pulled, for the console entry written when they finish.
    private var openStreams: [Int: (logged: String, start: Foundation.Date, typed: Bool)] = [:]

    private func finishStream(_ id: Int, rows: Int?, error: String? = nil) {
        guard let entry = openStreams.removeValue(forKey: id) else { return }
        logStatement(entry.logged, rows, error, Foundation.Date().timeIntervalSince(entry.start), typed: entry.typed)
    }

    /// Runs the query and returns the FIRST chunk immediately (instant paint) plus a
    /// handle to stream the rest. The query keeps producing on the DB actor under its
    /// own cursor id until `pullMore` reports it drained, or `closeStream` releases it.
    /// `pinJoinOrder` keeps the written join order (see SerialConnection.openStream).
    func openStreamingQuery(_ sql: String, firstChunk: Int, logSQL: String? = nil, lane: Lane = .user,
                            pinJoinOrder: Bool = false) async throws
        -> (result: QueryResult, stream: QueryStream) {
        let start = Date()
        let logged = logSQL ?? sql
        let s = serial(lane)
        let head: SerialConnection.StreamHead
        let first: SerialConnection.Pulled?
        do {
            head = try await s.openStream(sql, pinJoinOrder: pinJoinOrder)
            do {
                first = try await s.pull(firstChunk, id: head.id, probe: true)
            } catch {
                await s.closeStream(head.id)
                throw error
            }
        } catch {
            noteTransaction(sql, lane: lane, succeeded: false)
            logStatement(logged, nil, Self.extractReason(from: error), Date().timeIntervalSince(start))
            throw error
        }
        noteTransaction(sql, lane: lane, succeeded: true)
        var result = QueryResult(columns: head.columns,
                                 cells: first?.chunk.map { CellTable(chunk: $0) } ?? CellTable(columnCount: head.columns.count),
                                 executionTime: Date().timeIntervalSince(start))
        result.columnTypes = head.types.map { Self.duckDBTypeName($0) }
        result.totalRowCount = result.rowCount
        let hasMore = first?.hasMore ?? false
        if hasMore {
            openStreams[head.id] = (logged, start, StatementSource.typedByYou)
        } else {
            logStatement(logged, result.rowCount, nil, result.executionTime)
        }
        return (result, QueryStream(id: head.id, lane: lane, hasMore: hasMore))
    }

    /// Next chunk of a streaming query, or nil when fully delivered.
    func pullMore(_ stream: QueryStream, size: Int) async throws -> CellTable.Chunk? {
        do {
            guard let pulled = try await serial(stream.lane).pull(size, id: stream.id) else {
                finishStream(stream.id, rows: nil)
                return nil
            }
            if !pulled.hasMore { finishStream(stream.id, rows: pulled.delivered) }
            return pulled.chunk
        } catch {
            finishStream(stream.id, rows: nil, error: Self.extractReason(from: error))
            throw error
        }
    }

    /// Releases a streaming query's cursor when the caller stops early (cancel, or a new
    /// query supersedes it). Safe to call after it has already drained.
    func closeStream(_ stream: QueryStream) async {
        await serial(stream.lane).closeStream(stream.id)
        finishStream(stream.id, rows: nil, error: "Cancelled")
    }

    // MARK: - Server passthrough (fast path — the server does the work)
    //
    // WHY THIS EXISTS: DuckDB's ATTACH scanner does NOT push LIMIT/WHERE/ORDER BY down
    // to MySQL/Postgres — `SELECT * FROM alias.db.tbl LIMIT 200` fetches the WHOLE
    // table across the network, then discards all but 200 rows. On a 378M-row table
    // that is 18–31s+. Routing a single-server read through mysql_query()/postgres_query()
    // sends the SQL straight to the server, which applies LIMIT/WHERE/indexes natively
    // (~0.3s). This is exactly how Sequel Ace stays fast. Cross-engine JOINs still use
    // the scanner (that is the only path that can span servers).

    /// True when `alias` is a MySQL/Postgres server — the engines with a server-side
    /// passthrough table function. SQLite (local file) and ClickHouse (native client)
    /// have their own fast paths and are excluded.
    func hasServerPassthrough(_ alias: String) -> Bool {
        switch engine(for: alias) {
        case .mysql, .postgres: return true
        default:                return false
        }
    }

    /// Wraps a server-native statement in the engine's passthrough table function.
    /// `serverSQL` must be in the server's own dialect with no DuckDB alias prefix.
    private func passthroughWrap(alias: String, serverSQL: String) -> String? {
        switch engine(for: alias) {
        case .mysql:    return "SELECT * FROM mysql_query(\(SQLBuilder.literal(alias)), \(SQLBuilder.literal(serverSQL)))"
        case .postgres: return "SELECT * FROM postgres_query(\(SQLBuilder.literal(alias)), \(SQLBuilder.literal(serverSQL)))"
        default:        return nil
        }
    }

    /// Streaming SELECT pushed to a single MySQL/Postgres server. Same progressive
    /// contract as `openStreamingQuery` (first chunk instant, rest streams, no cap),
    /// but the server applies LIMIT/WHERE/indexes so a bounded query on a billion-row
    /// table returns immediately. The console logs the user's `serverSQL`, not the wrapper.
    func openServerStreamingQuery(alias: String, serverSQL: String, firstChunk: Int, lane: Lane = .user) async throws
        -> (result: QueryResult, stream: QueryStream) {
        guard let wrapped = passthroughWrap(alias: alias, serverSQL: serverSQL) else {
            throw SequelBridgeError.attachFailed("This connection has no server passthrough.")
        }
        return try await openStreamingQuery(wrapped, firstChunk: firstChunk, logSQL: serverSQL, lane: lane)
    }

    /// Non-streaming SELECT via the passthrough, for bounded results (content pages,
    /// counts). Logs `serverSQL` to the console rather than the wrapper.
    func serverPassthroughQuery(alias: String, serverSQL: String, lane: Lane = .user) async throws -> QueryResult {
        guard let wrapped = passthroughWrap(alias: alias, serverSQL: serverSQL) else {
            throw SequelBridgeError.attachFailed("This connection has no server passthrough.")
        }
        return try await query(wrapped, logSQL: serverSQL, lane: lane)
    }

    /// One page of a table's rows fetched server-side, so LIMIT/OFFSET/WHERE/ORDER BY
    /// all run on the server. Fully qualifies `db.table`, so it is correct for ANY
    /// database regardless of the connection's DSN default. MySQL/Postgres only. Runs on
    /// the Content lane so browsing never blocks (or is blocked by) a Query-tab query.
    func serverContentPage(alias: String, database: String, table: String,
                           filter: String, sortColumn: String?, sortAscending: Bool,
                           limit: Int, offset: Int) async throws -> QueryResult {
        var sql = "SELECT * FROM \(serverTableRef(alias: alias, database: database, table: table))"
        if !filter.isEmpty { sql += " WHERE \(filter)" }
        if let col = sortColumn, !col.isEmpty {
            sql += " ORDER BY \(SQLBuilder.serverIdent(engine(for: alias), col)) \(sortAscending ? "ASC" : "DESC")"
        }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return try await serverPassthroughQuery(alias: alias, serverSQL: sql, lane: .content)
    }

    /// Exact row count for a (possibly filtered) table, computed on the server.
    func serverContentCount(alias: String, database: String, table: String, filter: String) async throws -> Int {
        var sql = "SELECT COUNT(*) FROM \(serverTableRef(alias: alias, database: database, table: table))"
        if !filter.isEmpty { sql += " WHERE \(filter)" }
        let r = try await serverPassthroughQuery(alias: alias, serverSQL: sql, lane: .content)
        return Int(r.rows.first?.first ?? "") ?? 0
    }

    private func serverTableRef(alias: String, database: String, table: String) -> String {
        SQLBuilder.serverTable(engine(for: alias), database: database, table: table)
    }

    // MARK: - Cross-server inner-join reduction helpers

    /// True when the alias can run server-side passthrough queries: a MySQL/Postgres
    /// connection that carries a database in its DSN. mysql_query/postgres_query fetch
    /// a default schema to connect, so even a fully-qualified statement needs one.
    func canPassthrough(_ alias: String) -> Bool {
        hasServerPassthrough(alias) && !attachedDatabase(alias).isEmpty
    }

    /// Estimated row count from a table's cached metadata — fast (no table scan); nil
    /// when the server hasn't gathered stats. Only used to pick the smaller side of a
    /// join, so an estimate is enough and "unknown" simply defers to the other side.
    func tableRowEstimate(alias: String, database: String, table: String) async -> Int? {
        guard let meta = try? await fetchTableMeta(alias: alias, database: database, table: table),
              meta.count > 6, let n = Int(meta[6]) else { return nil }
        return n
    }

    /// Distinct values of one column, for a cross-server join reduction. Runs DISTINCT
    /// on the server via the passthrough when eligible, else through the scanner. Fully
    /// qualifies `database.table`, so it is correct for any database.
    func distinctKeys(alias: String, database: String, table: String, column: String,
                      where extraWhere: String? = nil, lane: Lane = .user) async throws -> QueryResult {
        if canPassthrough(alias) {
            // Pushed-down filters (server-quoted, see pushdownWhere) narrow the probe too.
            let sql = serverSelect(alias: alias, database: database, table: table,
                                   projection: "DISTINCT \(SQLBuilder.serverIdent(engine(for: alias), column))",
                                   conds: [extraWhere ?? ""])
            return try await serverPassthroughQuery(alias: alias, serverSQL: sql, lane: lane)
        } else {
            let sql = "SELECT DISTINCT \(SQLBuilder.duckIdent(column)) FROM \(SQLBuilder.duckTable(alias: alias, database: database, table: table))"
            return try await query(sql, lane: lane)
        }
    }

    /// A reduced passthrough subquery for the big side of a cross-server join:
    /// `SELECT * FROM mysql_query('alias','SELECT * FROM `db`.`table` WHERE `key` IN (list)')`.
    /// `keyList` is a ready-made value list (see SQLBuilder.inValueList). Only the
    /// matching rows cross the wire. nil when the alias has no passthrough; the caller
    /// wraps the result as a derived table with the big side's own alias.
    func reducedBigSide(alias: String, database: String, table: String,
                        keyColumn: String, keyList: String, extraWhere: String? = nil) -> String? {
        passthroughWrap(alias: alias, serverSQL: reducedBigSideServerSQL(
            alias: alias, database: database, table: table, keyColumn: keyColumn, keyList: keyList, extraWhere: extraWhere))
    }

    /// The server-native statement behind `reducedBigSide`, also what the planner asks
    /// the server to EXPLAIN before deciding to run it. `extraWhere` is the table's
    /// pushed-down filter (see pushdownWhere), applied alongside the key list.
    func reducedBigSideServerSQL(alias: String, database: String, table: String,
                                 keyColumn: String, keyList: String, extraWhere: String? = nil) -> String {
        serverSelect(alias: alias, database: database, table: table,
                     conds: [extraWhere ?? "", "\(SQLBuilder.serverIdent(engine(for: alias), keyColumn)) IN (\(keyList))"])
    }

    /// A whole table side of a cross-server join as a passthrough subquery, with its
    /// pushed-down filter — one bulk server round trip, instead of the raw ATTACH scanner
    /// dragging the table row by row (240s for a probe table on a real server). nil when
    /// the alias has no passthrough; a local SQLite table is a fast scanner read anyway.
    func passthroughTable(alias: String, database: String, table: String, extraWhere: String? = nil) -> String? {
        passthroughWrap(alias: alias, serverSQL: serverSelect(alias: alias, database: database, table: table,
                                                              conds: [extraWhere ?? ""]))
    }

    /// `SELECT <projection> FROM db.table [WHERE c1 AND c2] [LIMIT 0]` in the server's own
    /// dialect — the one shape every passthrough fetch of a table takes (whole,
    /// key-reduced, filtered, columns-only). Empty conditions are ignored.
    private func serverSelect(alias: String, database: String, table: String,
                              projection: String = "*", conds: [String], limitZero: Bool = false) -> String {
        let e = engine(for: alias)
        var sql = "SELECT \(projection) FROM \(SQLBuilder.serverTable(e, database: database, table: table))"
        let active = conds.filter { !$0.isEmpty }
        if !active.isEmpty { sql += " WHERE \(active.joined(separator: " AND "))" }
        if limitZero { sql += " LIMIT 0" }
        return sql
    }

    /// Longest key list inlined into a server-side `IN (…)`; beyond it the table is
    /// fetched whole (or the query falls back to the scanner).
    nonisolated static let maxInlineKeys = 10_000

    /// How to bring the big side of an inner equi-join over, given the probe's distinct
    /// keys. More than `maxInlineKeys` keys can't be inlined. Otherwise the server's
    /// optimizer says (EXPLAIN) how much of the table the key list selects, and above
    /// the threshold the whole table is cheaper (see SQLBuilder.crossJoinStrategy); no
    /// estimate → reduce.
    enum KeyReductionPlan: Equatable {
        case tooManyKeys
        case reduce(keyList: String)
        case fetchWhole
    }

    func keyReductionPlan(keys: QueryResult, alias: String, database: String, table: String,
                          keyColumn: String, extraWhere: String?, rowEstimate: Int?) async -> KeyReductionPlan {
        let vals = keys.rows.map { $0.first ?? "" }
        let msk  = keys.nullMask.map { $0.first ?? false }
        let nonNull = zip(vals, msk).filter { !$0.1 }.count
        guard nonNull <= Self.maxInlineKeys else { return .tooManyKeys }
        let inList = SQLBuilder.inValueList(vals, mask: msk)
        let serverSQL = reducedBigSideServerSQL(alias: alias, database: database, table: table,
                                                keyColumn: keyColumn, keyList: inList, extraWhere: extraWhere)
        let plan = try? await explain(alias: alias, serverSQL: serverSQL)
        let matched = plan.flatMap { SQLBuilder.explainEstimatedRows(columns: $0.columns, rows: $0.rows) }
        let strategy = SQLBuilder.crossJoinStrategy(estimatedMatchedRows: matched, bigRowEstimate: rowEstimate)
        return strategy == .fetchWhole ? .fetchWhole : .reduce(keyList: inList)
    }

    /// The DuckDB statement that runs a two-table cross-server inner join as two
    /// passthrough streams joined on arrival (see SQLBuilder.crossJoinRewrite). The
    /// smaller side is the probe: its distinct join keys reduce the bigger side's
    /// server SELECT when the server says that is selective, else the whole side comes
    /// (see keyReductionPlan); each side's own WHERE conjuncts, and those carried across
    /// the join key, are pushed to its server. A side with no passthrough (a local
    /// SQLite table) can only be the probe and stays a scanner ref. nil when neither
    /// side has a passthrough — the caller runs the scanner. Run the result with
    /// `pinJoinOrder`, so the big side, listed first, streams through the join.
    func crossJoinPlan(_ cj: SQLBuilder.CrossJoin, baseSQL: String, aliases: [String],
                       databaseFor: (String) -> String) async throws -> String? {
        let dbA = databaseFor(cj.a.server), dbB = databaseFor(cj.b.server)
        let estA = await tableRowEstimate(alias: cj.a.server, database: dbA, table: cj.a.table)
        let estB = await tableRowEstimate(alias: cj.b.server, database: dbB, table: cj.b.table)
        guard let bigIsA = SQLBuilder.crossJoinBigSide(estA: estA, estB: estB,
                                                       canA: canPassthrough(cj.a.server),
                                                       canB: canPassthrough(cj.b.server)) else { return nil }
        let big = bigIsA ? cj.a : cj.b, bigDB = bigIsA ? dbA : dbB
        let probe = bigIsA ? cj.b : cj.a, probeDB = bigIsA ? dbB : dbA
        let pushed = await pushdownWhere(baseSQL: baseSQL, aliases: aliases, databaseFor: databaseFor)
        func extra(_ side: SQLBuilder.CrossJoin.Side) -> String? {
            pushed[Self.pushdownKey(alias: side.server, table: side.table)]
        }
        let keys = try await distinctKeys(alias: probe.server, database: probeDB, table: probe.table,
                                          column: probe.key, where: extra(probe))
        let plan = await keyReductionPlan(keys: keys, alias: big.server, database: bigDB, table: big.table,
                                          keyColumn: big.key, extraWhere: extra(big), rowEstimate: bigIsA ? estA : estB)
        let bigRef: String?
        switch plan {
        case .reduce(let keyList):
            bigRef = reducedBigSide(alias: big.server, database: bigDB, table: big.table,
                                    keyColumn: big.key, keyList: keyList, extraWhere: extra(big))
        case .fetchWhole, .tooManyKeys:
            bigRef = passthroughTable(alias: big.server, database: bigDB, table: big.table, extraWhere: extra(big))
        }
        guard let bigRef else { return nil }
        // The probe side comes through the passthrough too, with its own pushed filter —
        // the raw scanner dragged a probe table row by row (240s measured) — or stays a
        // 3-part scanner ref when it has none (a local SQLite table: a fast local scan).
        let probeRef = passthroughTable(alias: probe.server, database: probeDB, table: probe.table,
                                        extraWhere: extra(probe)).map { "(\($0))" }
            ?? SQLBuilder.duckTable(alias: probe.server, database: probeDB, table: probe.table)
        return SQLBuilder.crossJoinRewrite(baseSQL, join: cj, bigIsA: bigIsA, bigRef: "(\(bigRef))", probeRef: probeRef)
    }

    // MARK: - Predicate pushdown for cross-server queries

    /// Key for `pushdownWhere`'s result: one entry per remote (connection alias, table).
    nonisolated static func pushdownKey(alias: String, table: String) -> String { alias + "\u{0}" + table }

    /// The server-side WHERE text each table of a multi-server SELECT can take — its own
    /// filters plus those carried to it across an inner-join key equality — keyed by
    /// `pushdownKey`. See SQLBuilder.pushdownPredicates for what qualifies; the column
    /// metadata it needs is read from each server (one SHOW per table). A table whose
    /// columns can't be read, or that the query names twice under different aliases,
    /// gets no pushdown. Never throws: "unknown" simply means the whole-table fetch of
    /// before.
    func pushdownWhere(baseSQL: String, aliases: [String],
                       databaseFor: (String) -> String) async -> [String: String] {
        guard let shape = SQLBuilder.analyzeSelect(baseSQL, aliases: aliases) else { return [:] }
        var columns: [String: [String: String]] = [:]
        var serverOf: [String: String] = [:]
        var uses: [String: Int] = [:]
        for t in shape.tables {
            serverOf[t.queryAlias] = t.server
            uses[Self.pushdownKey(alias: t.server, table: t.table), default: 0] += 1
            let db = t.database ?? databaseFor(t.server)
            guard !db.isEmpty,
                  let cols = try? await fetchColumns(alias: t.server, database: db, table: t.table) else { continue }
            columns[t.queryAlias] = Dictionary(cols.map { ($0.name, $0.dataType) }, uniquingKeysWith: { a, _ in a })
        }
        let engineOf = serverOf.mapValues { engine(for: $0) }
        let pushed = SQLBuilder.pushdownPredicates(shape, columns: columns) { alias, column in
            SQLBuilder.serverIdent(engineOf[alias] ?? .mysql, column)
        }
        var out: [String: String] = [:]
        for t in shape.tables {
            let key = Self.pushdownKey(alias: t.server, table: t.table)
            guard uses[key] == 1, let conj = pushed[t.queryAlias], !conj.isEmpty else { continue }
            out[key] = conj.map { "(\($0))" }.joined(separator: " AND ")
        }
        return out
    }

    /// Binds and plans `sql` on DuckDB without running it (EXPLAIN), so an unknown or
    /// ambiguous column in a cross-server query surfaces before any table crosses the
    /// wire. Throws DuckDB's own binder message. Not logged to the console — it is a
    /// check, not a statement the user ran. Runs on the lane whose TEMP tables the
    /// statement reads.
    func bindCheck(_ sql: String, lane: Lane = .user) async throws {
        let s = serial(lane)
        let head = try await s.openStream("EXPLAIN " + sql)
        await s.closeStream(head.id)
    }

    // MARK: - Cross-engine scanner fallback: materialize a remote table via passthrough

    /// Copies a whole MySQL/Postgres table into a DuckDB TEMP table through the fast
    /// passthrough, for a cross-engine query that no reduction can speed up (see
    /// SQLBuilder.planFallback). `CREATE TEMP TABLE AS SELECT * FROM mysql_query('alias',
    /// 'SELECT * FROM `db`.`table`')` makes DuckDB's own mysql/postgres extension do the
    /// bulk server-side fetch — the SAME extension and type mapping the raw ATTACH
    /// scanner uses, so the materialized rows are identical — instead of the scanner
    /// dragging the table across the wire row by row (~130x slower over a VPN). The join
    /// then runs entirely on local temp tables. `tempIdent` is the caller's already-
    /// DuckDB-quoted temp name (kept out of the alias namespace so expandAliases never
    /// touches it); it is returned for convenience and dropped afterward via dropTempTable.
    ///
    /// `extraWhere` is the table's pushed-down filter (see pushdownWhere): the user's
    /// own conjuncts on this table, applied by the server so an indexed lookup stays a
    /// lookup instead of a whole-table transfer. `shapeOnly` fetches the columns but no
    /// rows (`LIMIT 0`), to bind the rewritten query before the real fetch.
    func materializeViaPassthrough(alias: String, database: String, table: String,
                                   tempIdent: String, extraWhere: String? = nil, shapeOnly: Bool = false,
                                   lane: Lane = .user) async throws -> String {
        let serverSQL = serverSelect(alias: alias, database: database, table: table,
                                     conds: [extraWhere ?? ""], limitZero: shapeOnly)
        guard let wrapped = passthroughWrap(alias: alias, serverSQL: serverSQL) else {
            throw SequelBridgeError.attachFailed("\(alias) has no server passthrough to materialize \(table).")
        }
        let logged = shapeOnly ? serverSQL + "  -- columns only: binding the query before fetching" : serverSQL
        _ = try await query("CREATE OR REPLACE TEMP TABLE \(tempIdent) AS \(wrapped)", logSQL: logged, lane: lane)
        return tempIdent
    }

    // MARK: - Schema browsing (via ATTACH'd MySQL information_schema)

    /// Public entry point for schema/panel queries — routes to metaSerial (in-memory catalog, instant).
    func schemaQuery(_ sql: String) async throws -> QueryResult {
        return try await metaQuery(sql)
    }

    /// Runs a query on the dedicated metadata connection so it never blocks user queries.
    /// Same as metaQuery/sidebarQuery, reachable from the per-engine extensions.
    func metaQueryPublic(_ sql: String) async throws -> QueryResult { try await metaQuery(sql) }
    func sidebarQueryPublic(_ sql: String) async throws -> QueryResult { try await sidebarQuery(sql) }

    private func metaQuery(_ sql: String) async throws -> QueryResult {
        let start = Date()
        let resultSet: ResultSet
        do { resultSet = try await metaSerial.query(sql) } catch {
            logStatement(sql, nil, Self.extractReason(from: error), Date().timeIntervalSince(start), appsOwn: true)
            throw error
        }
        let colCount = Int(resultSet.columnCount)
        let rowCount = Int(resultSet.rowCount)
        let columns = (0..<colCount).map { resultSet.columnName(at: DBInt($0)) }
        var colData: [[String?]] = []
        for ci in 0..<colCount {
            colData.append(Self.extractColumn(resultSet, colIndex: ci, rowRange: 0..<rowCount))
        }
        var result = QueryResult(columns: columns, cells: CellTable(chunk: .init(columns: colData, rowCount: rowCount)),
                                 executionTime: Date().timeIntervalSince(start))
        result.columnTypes = (0..<colCount).map { Self.duckDBTypeName(resultSet[DBInt($0)].underlyingDatabaseType) }
        logStatement(sql, rowCount, nil, result.executionTime, appsOwn: true)
        return result
    }

    /// Dedicated connection for information_schema.tables — isolated from metaSerial so a slow
    /// stats query never blocks the fast duckdb_columns/duckdb_constraints structure load.
    private func sidebarQuery(_ sql: String) async throws -> QueryResult {
        let start = Date()
        let resultSet: ResultSet
        do { resultSet = try await sidebarSerial.query(sql) } catch {
            logStatement(sql, nil, Self.extractReason(from: error), Date().timeIntervalSince(start), appsOwn: true)
            throw error
        }
        let colCount = Int(resultSet.columnCount)
        let rowCount = Int(resultSet.rowCount)
        let columns = (0..<colCount).map { resultSet.columnName(at: DBInt($0)) }
        var colData: [[String?]] = []
        for ci in 0..<colCount { colData.append(Self.extractColumn(resultSet, colIndex: ci, rowRange: 0..<rowCount)) }
        var result = QueryResult(columns: columns, cells: CellTable(chunk: .init(columns: colData, rowCount: rowCount)),
                                 executionTime: Date().timeIntervalSince(start))
        result.columnTypes = (0..<colCount).map { Self.duckDBTypeName(resultSet[DBInt($0)].underlyingDatabaseType) }
        logStatement(sql, rowCount, nil, result.executionTime, appsOwn: true)
        return result
    }

    /// Returns full table metadata using SHOW TABLE STATUS via mysql_query().
    ///
    /// WHY THIS IS FAST:
    /// • mysql_query() sends SQL directly to MySQL, bypassing DuckDB's query planner.
    /// • DuckDB's planner was the problem: it fetched ALL rows from information_schema.tables
    ///   and filtered locally, triggering InnoDB stat recalculation for all 461 tables.
    /// • SHOW TABLE STATUS WHERE Name = 'x' is what Sequel Ace itself uses — MySQL only
    ///   processes the one matching table using cached InnoDB stats. O(1) lookup.
    ///
    /// Returns all fields Sequel Ace shows: engine, rows, sizes, collation, timestamps, comment.

    // MARK: - Metadata dispatch

    /// Native ClickHouse connections, keyed by alias. These live outside DuckDB.
    var clickhouseClients: [String: ClickHouseClient] = [:]

    /// Which product backs an alias. Unknown aliases predate multi-engine support.
    private func engine(for alias: String) -> DatabaseEngine { engines[alias] ?? .mysql }

    func sqlitePath(for alias: String) -> String? { sqlitePaths[alias] }

    func fetchDatabases(alias: String) async throws -> [String] {
        switch engine(for: alias) {
        case .mysql:    return try await fetchDatabasesMySQL(alias: alias)
        case .postgres: return try await fetchDatabasesPostgres(alias: alias)
        case .sqlite:   return try await fetchDatabasesSQLite(alias: alias)
        case .clickhouse: return try await fetchDatabasesClickHouse(alias: alias)
        }
    }

    func fetchTables(alias: String, database: String) async throws -> [TableInfo] {
        switch engine(for: alias) {
        case .mysql:    return try await fetchTablesMySQL(alias: alias, database: database)
        case .postgres: return try await fetchTablesPostgres(alias: alias, database: database)
        case .sqlite:   return try await fetchTablesSQLite(alias: alias, database: database)
        case .clickhouse: return try await fetchTablesClickHouse(alias: alias, database: database)
        }
    }

    func fetchColumns(alias: String, database: String, table: String) async throws -> [ColumnInfo] {
        switch engine(for: alias) {
        case .mysql:    return try await fetchColumnsMySQL(alias: alias, database: database, table: table)
        case .postgres: return try await fetchColumnsPostgres(alias: alias, database: database, table: table)
        case .sqlite:   return try await fetchColumnsSQLite(alias: alias, database: database, table: table)
        case .clickhouse: return try await fetchColumnsClickHouse(alias: alias, database: database, table: table)
        }
    }

    func fetchIndexes(alias: String, database: String, table: String) async throws -> [IndexInfo] {
        switch engine(for: alias) {
        case .mysql:    return try await fetchIndexesMySQL(alias: alias, database: database, table: table)
        case .postgres: return try await fetchIndexesPostgres(alias: alias, database: database, table: table)
        case .sqlite:   return try await fetchIndexesSQLite(alias: alias, database: database, table: table)
        case .clickhouse: return try await fetchIndexesClickHouse(alias: alias, database: database, table: table)
        }
    }

    func fetchRelations(alias: String, database: String, table: String) async throws -> [[String]] {
        switch engine(for: alias) {
        case .mysql:    return try await fetchRelationsMySQL(alias: alias, database: database, table: table)
        case .postgres: return try await fetchRelationsPostgres(alias: alias, database: database, table: table)
        case .sqlite:   return try await fetchRelationsSQLite(alias: alias, database: database, table: table)
        case .clickhouse: return []   // ClickHouse has no foreign keys
        }
    }

    func fetchTriggers(alias: String, database: String, table: String) async throws -> [[String]] {
        switch engine(for: alias) {
        case .mysql:    return try await fetchTriggersMySQL(alias: alias, database: database, table: table)
        case .postgres: return try await fetchTriggersPostgres(alias: alias, database: database, table: table)
        case .sqlite:   return try await fetchTriggersSQLite(alias: alias, database: database, table: table)
        case .clickhouse: return []   // ClickHouse has no triggers
        }
    }

    func fetchTableMeta(alias: String, database: String, table: String) async throws -> [String] {
        switch engine(for: alias) {
        case .mysql:    return try await fetchTableMetaMySQL(alias: alias, database: database, table: table)
        case .postgres: return try await fetchTableMetaPostgres(alias: alias, database: database, table: table)
        case .sqlite:   return try await fetchTableMetaSQLite(alias: alias, database: database, table: table)
        case .clickhouse: return try await fetchTableMetaClickHouse(alias: alias, database: database, table: table)
        }
    }

    func fetchTableMetaMySQL(alias: String, database: String, table: String) async throws -> [String] {
        let key = "\(alias).\(database).\(table)"
        if let cached = tableMetaCache[key] { return cached }

        // Escape for embedding inside a DuckDB single-quoted string that itself contains MySQL SQL.
        // Single quotes in the table/db name become '' (DuckDB escape) which MySQL sees as '.
        let dbEsc  = database.replacingOccurrences(of: "`",  with: "``")   // backtick escape for MySQL identifier
        let tblEsc = table.replacingOccurrences(of: "'", with: "''")        // DuckDB string escape
        let aliEsc = alias.replacingOccurrences(of: "'", with: "''")

        let sql = """
            SELECT * FROM mysql_query('\(aliEsc)',
              'SHOW TABLE STATUS FROM `\(dbEsc)` WHERE Name = ''\(tblEsc)''')
        """
        // SHOW TABLE STATUS columns (0-based):
        // 0:Name  1:Engine  2:Version  3:Row_format  4:Rows  5:Avg_row_length
        // 6:Data_length  7:Max_data_length  8:Index_length  9:Data_free  10:Auto_increment
        // 11:Create_time  12:Update_time  13:Check_time  14:Collation
        // 15:Checksum  16:Create_options  17:Comment

        let result = try? await sidebarQuery(sql)
        let r = result?.rows.first ?? []

        // Map to the 15-element layout callers expect:
        // [0]=engine [1]=row_format [2]=auto_increment [3]=collation [4]=create_options [5]=comment
        // [6]=rows   [7]=avg_row_len [8]=data_length   [9]=max_data  [10]=index_length  [11]=data_free
        // [12]=create_time [13]=update_time [14]=check_time
        let row: [String] = [
            r.count > 1  ? r[1]  : "",   // engine
            r.count > 3  ? r[3]  : "",   // row_format
            r.count > 10 ? r[10] : "",   // auto_increment
            r.count > 14 ? r[14] : "",   // collation
            r.count > 16 ? r[16] : "",   // create_options
            r.count > 17 ? r[17] : "",   // comment
            r.count > 4  ? r[4]  : "",   // rows
            r.count > 5  ? r[5]  : "",   // avg_row_length
            r.count > 6  ? r[6]  : "",   // data_length
            r.count > 7  ? r[7]  : "",   // max_data_length
            r.count > 8  ? r[8]  : "",   // index_length
            r.count > 9  ? r[9]  : "",   // data_free
            r.count > 11 ? r[11] : "",   // create_time
            r.count > 12 ? r[12] : "",   // update_time
            r.count > 13 ? r[13] : "",   // check_time
        ]
        tableMetaCache[key] = row
        return row
    }

    struct SQLDumpResult {
        let text: String
        let rowCount: Int
        let truncated: Bool
    }

    /// Builds a MySQL/MariaDB SQL dump for one table: the server's authoritative
    /// `SHOW CREATE TABLE` statement plus batched, NULL-mask-aware INSERTs for up
    /// to `rowLimit` rows. `truncated` is true when the table may hold more rows
    /// than were dumped.
    func sqlDump(alias: String, database: String, table: String, rowLimit: Int = 100_000) async throws -> SQLDumpResult {
        // 1) CREATE TABLE — the server's exact statement via the native client. (SHOW
        //    CREATE TABLE can't run through mysql_scanner's mysql_query on MariaDB.) When
        //    that client can't run it (a connection with Use SSL, a server it can't log in
        //    to), rebuild it from column/index/table metadata, which has no FOREIGN KEY
        //    lines, and say so in the dump.
        let create = try await fetchCreateTable(alias: alias, database: database, table: table)
        let createStatement = create.statement
        var rebuiltNote: [String] = []
        if create.rebuilt {
            rebuiltNote = ["-- The server's own CREATE TABLE couldn't be read, so this one is rebuilt from the",
                           "-- table's columns and indexes, without foreign keys. Reason: \(create.reason ?? "unknown")"]
        }

        // 2) Data — the query is already bounded by its own LIMIT; the result grid
        //    no longer caps rows, so nothing here clips the dump.
        let dref = SQLBuilder.duckTable(alias: alias, database: database, table: table)
        let data = try await query("SELECT * FROM \(dref) LIMIT \(rowLimit)")
        let inserts = SQLBuilder.dumpInsertStatements(
            table: table, columns: data.columns, rows: data.rows, nullMask: data.nullMask)

        // 3) Assemble.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines: [String] = [
            "-- SequelBridge SQL dump",
            "-- Table: \(database).\(table)",
            "-- Generated: \(df.string(from: Date()))",
        ] + rebuiltNote + [
            "",
            "DROP TABLE IF EXISTS \(SQLBuilder.mysqlIdent(table));",
            createStatement + ";",
            "",
        ]
        if inserts.isEmpty {
            lines.append("-- (no rows)")
        } else {
            lines.append(contentsOf: inserts)
        }
        return SQLDumpResult(text: lines.joined(separator: "\n") + "\n",
                             rowCount: data.rowCount,
                             truncated: data.rowCount >= rowLimit)
    }

    /// Dumps every table in a database (schema + data) into one SQL script, in the
    /// server's table order. `truncated` is true if ANY table hit the per-table row cap.
    func sqlDumpDatabase(alias: String, database: String, rowLimit: Int = 100_000) async throws -> SQLDumpResult {
        let tables = try await fetchTables(alias: alias, database: database)
        var parts: [String] = ["-- SequelBridge dump of `\(database)` — \(Plural.count(tables.count, "table"))\n"]
        var totalRows = 0
        var anyTruncated = false
        for t in tables {
            let d = try await sqlDump(alias: alias, database: database, table: t.name, rowLimit: rowLimit)
            parts.append("-- ----------------------------\n-- Table: \(t.name)\n-- ----------------------------")
            parts.append(d.text)
            totalRows += d.rowCount
            anyTruncated = anyTruncated || d.truncated
        }
        return SQLDumpResult(text: parts.joined(separator: "\n"), rowCount: totalRows, truncated: anyTruncated)
    }

    // MARK: - Server inspection (process list, variables, status)

    /// Runs a raw statement on the server via the per-engine passthrough and returns
    /// the grid. For server-admin views (process list, variables, status).
    private func serverPassthrough(_ alias: String, _ sql: String) async throws -> QueryResult {
        switch engine(for: alias) {
        case .mysql:    return try await query("SELECT * FROM mysql_query(\(SQLBuilder.literal(alias)), \(SQLBuilder.literal(sql)))")
        case .postgres: return try await query("SELECT * FROM postgres_query(\(SQLBuilder.literal(alias)), \(SQLBuilder.literal(sql)))")
        default:        return QueryResult(columns: [], rows: [], executionTime: 0)
        }
    }

    /// Live process/connection list. MySQL: information_schema.PROCESSLIST (SHOW FULL
    /// PROCESSLIST can't run through mysql_query on mysql_scanner 1.5.6 — "failed to
    /// fetch return types" — but the IS view is a regular SELECT that works); Postgres:
    /// pg_stat_activity.
    func serverProcesses(alias: String) async throws -> QueryResult {
        switch engine(for: alias) {
        case .mysql:    return try await serverPassthrough(alias,
            "SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, INFO FROM information_schema.PROCESSLIST ORDER BY ID")
        case .postgres: return try await serverPassthrough(alias,
            "SELECT pid, usename, client_addr, datname, state, wait_event_type, query FROM pg_stat_activity ORDER BY pid")
        default:        return QueryResult(columns: [], rows: [], executionTime: 0)
        }
    }

    /// Server configuration variables. MySQL: SHOW VARIABLES; Postgres: pg_settings.
    func serverVariables(alias: String) async throws -> QueryResult {
        switch engine(for: alias) {
        case .mysql:    return try await serverPassthrough(alias, "SHOW VARIABLES")
        case .postgres: return try await serverPassthrough(alias, "SELECT name, setting, unit, category FROM pg_settings ORDER BY name")
        default:        return QueryResult(columns: [], rows: [], executionTime: 0)
        }
    }

    /// Runtime status counters. MySQL: SHOW GLOBAL STATUS; Postgres: per-database stats.
    func serverStatus(alias: String) async throws -> QueryResult {
        switch engine(for: alias) {
        case .mysql:    return try await serverPassthrough(alias, "SHOW GLOBAL STATUS")
        case .postgres: return try await serverPassthrough(alias,
            "SELECT datname, numbackends, xact_commit, xact_rollback, blks_read, blks_hit, tup_returned, tup_fetched FROM pg_stat_database WHERE datname IS NOT NULL ORDER BY datname")
        default:        return QueryResult(columns: [], rows: [], executionTime: 0)
        }
    }

    /// Terminates a server-side session by id. MySQL: KILL; Postgres: pg_terminate_backend.
    /// The id is coerced to an integer so a grid cell can't inject SQL.
    func killProcess(alias: String, id: String) async throws {
        try ensureWritable(alias)
        let pid = Int(id.trimmingCharacters(in: .whitespaces)) ?? -1
        guard pid >= 0 else { throw SequelBridgeError.attachFailed("Invalid process id") }
        switch engine(for: alias) {
        case .mysql:    try await executeDDL(alias: alias, sql: "KILL \(pid)")
        case .postgres: _ = try await serverPassthrough(alias, "SELECT pg_terminate_backend(\(pid))")
        default:        break
        }
    }

    /// Stored procedures and functions for a schema, read from the server's own
    /// information_schema.ROUTINES via the per-engine passthrough (so it sees the
    /// real server catalog, not DuckDB's). Each row: [name, type, returns, body].
    /// MySQL/Postgres only; other engines return []. Does not touch table stats, so
    /// it stays fast even on schemas with thousands of tables.
    func fetchRoutines(alias: String, database: String) async throws -> [[String]] {
        // Each column named: PostgreSQL calls both COALESCEs "coalesce", which DuckDB refuses.
        let inner = "SELECT ROUTINE_NAME, ROUTINE_TYPE, COALESCE(DTD_IDENTIFIER,'') AS RETURNS_TYPE, COALESCE(ROUTINE_DEFINITION,'') AS BODY "
            + "FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(SQLBuilder.literal(database)) "
            + "ORDER BY ROUTINE_TYPE, ROUTINE_NAME"
        let wrapped: String
        switch engine(for: alias) {
        case .mysql:    wrapped = "SELECT * FROM mysql_query(\(SQLBuilder.literal(alias)), \(SQLBuilder.literal(inner)))"
        case .postgres: wrapped = "SELECT * FROM postgres_query(\(SQLBuilder.literal(alias)), \(SQLBuilder.literal(inner)))"
        default:        return []
        }
        return (try await metaQueryPublic(wrapped)).rows
    }

    /// Runs a statement through the native MySQL client (not mysql_scanner) — for the few
    /// statements the scanner can't prepare on MariaDB: EXPLAIN and exact SHOW CREATE
    /// TABLE. Values come back as strings with a NULL mask, matching the scanner path.
    /// Import SQL file: runs `statements` in order on the server, reporting each one done.
    /// The first that fails stops the run with a SQLScriptFailure naming it; Stop (task
    /// cancellation) ends it between statements. A `USE` goes to `use` when given, so the
    /// app can pick that database the way the Query tab does.
    func runScript(alias: String, statements: [String], use: ((String) async throws -> Void)? = nil,
                   onProgress: (Int) -> Void) async throws {
        for (i, statement) in statements.enumerated() {
            try Task.checkCancellation()
            if let reason = SQLFile.unsupported(statement) {
                throw SQLScriptFailure(index: i + 1, total: statements.count, reason: reason)
            }
            do {
                if let db = QueryEffects.soleUse(statement), let use {
                    try await use(db)
                } else {
                    try await executeDDL(alias: alias, sql: statement)
                }
            } catch {
                throw SQLScriptFailure(index: i + 1, total: statements.count, reason: Self.extractReason(from: error))
            }
            onProgress(i + 1)
        }
    }

    /// A table's CREATE TABLE statement, as Table Info shows it: the server's own on MySQL
    /// (SHOW CREATE TABLE, on the app's own MySQL client) and ClickHouse, the file's own on
    /// SQLite. Where none can be read (PostgreSQL keeps none; a MySQL connection with Use
    /// SSL; a server that client can't log in to), it is rebuilt from the columns and
    /// indexes, without foreign keys, and `rebuilt` says so.
    func fetchCreateTable(alias: String, database: String, table: String) async throws
        -> (statement: String, rebuilt: Bool, reason: String?) {
        switch engine(for: alias) {
        case .mysql:
            do {
                let showCreate = "SHOW CREATE TABLE \(SQLBuilder.mysqlTable(database: database, table: table))"
                let r = try await nativeMySQLQuery(alias: alias, sql: showCreate, logSQL: showCreate)
                guard let first = r.rows.first, first.count > 1, !first[1].isEmpty else {
                    throw SequelBridgeError.attachFailed("empty CREATE TABLE")
                }
                return (first[1], false, nil)
            } catch {
                let reason = Self.extractReason(from: error).replacingOccurrences(of: "\n", with: " ")
                return (try await rebuiltCreateTable(alias: alias, database: database, table: table), true, reason)
            }
        case .clickhouse:
            let sql = "SHOW CREATE TABLE \(SQLBuilder.duckIdent(database)).\(SQLBuilder.duckIdent(table))"
            if let own = try? await clickhouseQuery(alias: alias, sql: sql).rows.first?.first, !own.isEmpty {
                return (own, false, nil)
            }
            return (try await rebuiltCreateTable(alias: alias, database: database, table: table), true, nil)
        case .sqlite:
            let own = try await sqliteCreateStatement(alias, table: table)
            if !own.isEmpty { return (own, false, nil) }
            return (try await rebuiltCreateTable(alias: alias, database: database, table: table), true, nil)
        case .postgres:
            return (try await rebuiltCreateTable(alias: alias, database: database, table: table), true, nil)
        }
    }

    /// CREATE TABLE rebuilt from the columns, indexes and table options: no foreign keys.
    private func rebuiltCreateTable(alias: String, database: String, table: String) async throws -> String {
        let cols = try await fetchColumns(alias: alias, database: database, table: table)
        let idxs = try await fetchIndexes(alias: alias, database: database, table: table)
        let meta = (try? await fetchTableMeta(alias: alias, database: database, table: table)) ?? []
        func m(_ i: Int) -> String { i < meta.count ? meta[i] : "" }
        // meta layout: [0]=engine [2]=auto_increment [3]=collation [5]=comment
        return SQLBuilder.showCreateTable(table: table, columns: cols, indexes: idxs,
                                          engine: m(0), collation: m(3), autoIncrement: m(2), comment: m(5))
    }

    /// Runs a Table Maintenance task on the native client, which returns the server's
    /// answer (a read through the passthrough can't run every one of them), and reads it.
    func tableMaintenance(_ task: TableMaintenance, alias: String, database: String, table: String) async throws -> String {
        if task.changesTheTable { try ensureWritable(alias) }
        // CHECK and CHECKSUM only read, though their words aren't a read's.
        let answer = try await nativeMySQLRun(alias: alias, sql: task.sql(database: database, table: table))
        return TableMaintenance.summary(columns: answer.columns, rows: answer.rows)
    }

    func nativeMySQLQuery(alias: String, sql: String, logSQL: String? = nil, database: String? = nil) async throws -> QueryResult {
        try ensureReads(sql, alias: alias)
        return try await nativeMySQLRun(alias: alias, sql: sql, logSQL: logSQL, database: database)
    }

    /// A statement the passthrough can't run (QueryEffects.runsOnNativeClient), on the
    /// app's own client for the server: in `database` when given, a MySQL database or a
    /// PostgreSQL schema.
    func nativeQuery(alias: String, sql: String, database: String?) async throws -> QueryResult {
        switch engine(for: alias) {
        case .mysql:    return try await nativeMySQLQuery(alias: alias, sql: sql, database: database)
        case .postgres: return try await nativePostgresQuery(alias: alias, sql: sql, schema: database)
        case .sqlite, .clickhouse:
            throw SequelBridgeError.attachFailed("This connection has no client of the app's own.")
        }
    }

    /// Runs `sql` on PostgreSQL's own client (see PostgresClient), in `schema` when given.
    func nativePostgresQuery(alias: String, sql: String, schema: String? = nil, logSQL: String? = nil) async throws -> QueryResult {
        try ensureReads(sql, alias: alias)
        guard let cfg = postgresConfigs[alias] else {
            throw SequelBridgeError.attachFailed("No PostgreSQL connection named '\(alias)'.")
        }
        let sent = schema.map { "SET search_path TO \(SQLBuilder.duckIdent($0)); \(sql)" } ?? sql
        let start = Date()
        do {
            let (cols, rows) = try await PostgresClient(cfg).query(sent)
            var result = QueryResult(columns: cols,
                                     rows: rows.map { $0.map { $0 ?? "NULL" } },
                                     executionTime: Date().timeIntervalSince(start))
            result.nullMask = rows.map { $0.map { $0 == nil } }
            result.totalRowCount = rows.count
            logStatement(logSQL ?? sql, rows.count, nil, result.executionTime)
            return result
        } catch {
            logStatement(logSQL ?? sql, nil, Self.extractReason(from: error), Date().timeIntervalSince(start))
            throw error
        }
    }

    private func nativeMySQLRun(alias: String, sql: String, logSQL: String? = nil, database: String? = nil) async throws -> QueryResult {
        guard var cfg = mysqlConfigs[alias] else {
            throw SequelBridgeError.attachFailed("No MySQL connection named '\(alias)'.")
        }
        if let database, !database.isEmpty { cfg.database = database }
        let start = Date()
        do {
            let (cols, rows) = try await MySQLClient(cfg).query(sql)
            var result = QueryResult(columns: cols,
                                     rows: rows.map { $0.map { $0 ?? "NULL" } },
                                     executionTime: Date().timeIntervalSince(start))
            result.nullMask = rows.map { $0.map { $0 == nil } }
            result.totalRowCount = rows.count
            logStatement(logSQL ?? sql, rows.count, nil, result.executionTime)
            return result
        } catch {
            logStatement(logSQL ?? sql, nil, Self.extractReason(from: error), Date().timeIntervalSince(start))
            throw error
        }
    }

    /// Runs the server's *native* EXPLAIN for a single-server query and returns the
    /// plan grid (MySQL: id/select_type/table/type/key/rows/Extra; Postgres: the
    /// query plan text). `serverSQL` must already have the DuckDB alias prefix
    /// stripped, since it executes on the server directly against its default db.
    func explain(alias: String, serverSQL: String, database: String? = nil) async throws -> QueryResult {
        let explainSQL = "EXPLAIN \(serverSQL)"
        try ensureReads(explainSQL, alias: alias)
        switch engine(for: alias) {
        case .mysql:
            // mysql_scanner can't run EXPLAIN through mysql_query on MariaDB (it prepares
            // every statement to learn its result types, and EXPLAIN isn't preparable), so
            // run it on the native client instead — full server-native EXPLAIN, no degrade.
            return try await nativeMySQLQuery(alias: alias, sql: explainSQL, logSQL: explainSQL, database: database)
        case .postgres:
            // postgres_query nests every statement as a subquery, where PostgreSQL takes no
            // EXPLAIN, so it runs on PostgreSQL's own client.
            return try await nativePostgresQuery(alias: alias, sql: explainSQL, schema: database, logSQL: explainSQL)
        case .clickhouse:
            return try await clickhouseQuery(alias: alias, sql: explainSQL)
        case .sqlite:
            return try await query("EXPLAIN QUERY PLAN \(serverSQL)")
        }
    }

    /// Imports parsed CSV rows into an existing table via batched INSERTs on the
    /// per-engine executeDDL path. Returns the number of rows sent. Only MySQL/PG
    /// (the engines with a proven executeDDL path) are offered in the UI.
    func importCSV(alias: String, database: String, table: String,
                   columns: [String], rows: [[String]]) async throws -> Int {
        let statements = SQLBuilder.insertRows(engine: engine(for: alias), database: database,
                                               table: table, columns: columns, rows: rows)
        for sql in statements {
            try await executeDDL(alias: alias, sql: sql)
        }
        return rows.count
    }

    func fetchTablesMySQL(alias: String, database: String) async throws -> [TableInfo] {
        // Use SHOW FULL TABLES via mysql_query() for the same reason as fetchDatabases:
        // DuckDB's information_schema.tables may only see tables from the attached schema.
        // SHOW FULL TABLES sends directly to MySQL and always returns the real list.
        let aliasEsc = alias.replacingOccurrences(of: "'", with: "''")
        let dbEsc    = database.replacingOccurrences(of: "`", with: "``")
        let sql = "SELECT * FROM mysql_query('\(aliasEsc)', 'SHOW FULL TABLES FROM `\(dbEsc)`')"
        let result = try await metaQuery(sql)
        // SHOW FULL TABLES returns: Tables_in_<db>(0), Table_type(1) — BASE TABLE or VIEW
        return result.rows.compactMap { row -> TableInfo? in
            guard row.count >= 2, !row[0].isEmpty else { return nil }
            let type: TableType = row[1].uppercased().contains("VIEW") ? .view : .table
            return TableInfo(id: "\(alias).\(row[0])", name: row[0], type: type, alias: alias)
        }
    }

    /// The server's encodings, for Add Database (MySQL).
    func fetchCharsets(alias: String) async throws -> [String] {
        try await mysqlMeta(alias, "SELECT CHARACTER_SET_NAME FROM information_schema.CHARACTER_SETS ORDER BY CHARACTER_SET_NAME")
            .rows.compactMap(\.first).filter { !$0.isEmpty }
    }

    /// The server's collations, for Add Database (MySQL).
    func fetchCollations(alias: String) async throws -> [DatabaseCollation] {
        try await mysqlMeta(alias, "SELECT COLLATION_NAME, CHARACTER_SET_NAME, IS_DEFAULT FROM information_schema.COLLATIONS")
            .rows.compactMap { r in
                guard r.count >= 3, !r[0].isEmpty else { return nil }
                return DatabaseCollation(name: r[0], charset: r[1], isDefault: r[2].caseInsensitiveCompare("Yes") == .orderedSame)
            }
    }

    /// The encoding and collation a new database gets by default (MySQL).
    func serverDefaults(alias: String) async throws -> (charset: String, collation: String) {
        let row = try await mysqlMeta(alias, "SELECT @@character_set_server, @@collation_server").rows.first ?? []
        return (row.first ?? "", row.count > 1 ? row[1] : "")
    }

    /// A read on `alias`'s MySQL server through the passthrough, on the metadata lane.
    /// `serverSQL` mustn't hold a single quote: it goes inside mysql_query('…').
    private func mysqlMeta(_ alias: String, _ serverSQL: String) async throws -> QueryResult {
        let aliasEsc = alias.replacingOccurrences(of: "'", with: "''")
        return try await metaQuery("SELECT * FROM mysql_query('\(aliasEsc)', '\(serverSQL)')")
    }

    func fetchDatabasesMySQL(alias: String) async throws -> [String] {
        // Use SHOW DATABASES via mysql_query() — bypasses DuckDB's virtual information_schema
        // which only reflects schemas loaded at ATTACH time (often just the one in the DSN).
        // mysql_query sends directly to MySQL and returns the real list of accessible databases.
        let aliasEsc = alias.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT * FROM mysql_query('\(aliasEsc)', 'SHOW DATABASES')"
        let result = try await metaQuery(sql)
        let systemDBs: Set<String> = [
            "information_schema", "performance_schema", "mysql", "sys",
            // TiDB's system schemas — it speaks the MySQL protocol and works as a
            // MySQL-engine connection.
            "metrics_schema", "inspection_schema",
            "innodb", "tmp", "#innodb_temp"
        ]
        return result.rows
            .compactMap { $0.first }
            .filter { !$0.isEmpty && !systemDBs.contains($0.lowercased()) }
            .sorted()
    }

    /// Foreign keys read from information_schema. (SHOW CREATE TABLE stopped working
    /// through mysql_query on mysql_scanner 1.5.6 — "failed to fetch return types" —
    /// so we read KEY_COLUMN_USAGE + REFERENTIAL_CONSTRAINTS, which return a regular
    /// result set the scanner can introspect. GROUP_CONCAT keeps multi-column keys
    /// together, ordered by position. Each row: [name, cols, refTable, refCols, onDelete, onUpdate].
    func fetchRelationsMySQL(alias: String, database: String, table: String) async throws -> [[String]] {
        let inner = Self.mysqlRelationsSQL(database: database, table: table)
        guard let sql = passthroughWrap(alias: alias, serverSQL: inner),
              let result = try? await metaQuery(sql) else { return [] }
        return result.rows.compactMap { r in
            guard r.count >= 6, !r[0].isEmpty, !r[2].isEmpty else { return nil }
            let del = r[4].isEmpty ? "RESTRICT" : r[4].uppercased()
            let upd = r[5].isEmpty ? "RESTRICT" : r[5].uppercased()
            return [r[0], r[1], r[2], r[3], del, upd]
        }
    }

    /// The server-side SQL behind fetchRelationsMySQL, for the foreign keys of one table.
    /// Both sides are pinned to the table with literals and meet on the key's name only.
    /// MariaDB (like MySQL before 8) reads one table's constraints only when the schema and
    /// table are compared with literals; joined on the other side's schema and table
    /// columns instead, REFERENTIAL_CONSTRAINTS opened every table in every database.
    nonisolated static func mysqlRelationsSQL(database: String, table: String) -> String {
        // MySQL-level string literals (quotes doubled); doubled again for the DuckDB embedding.
        let dbLit  = database.replacingOccurrences(of: "'", with: "''")
        let tblLit = table.replacingOccurrences(of: "'", with: "''")
        return "SELECT k.CONSTRAINT_NAME, "
            + "GROUP_CONCAT(k.COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ', '), "
            + "k.REFERENCED_TABLE_NAME, "
            + "GROUP_CONCAT(k.REFERENCED_COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ', '), "
            + "r.DELETE_RULE, r.UPDATE_RULE "
            + "FROM information_schema.KEY_COLUMN_USAGE k "
            + "JOIN information_schema.REFERENTIAL_CONSTRAINTS r ON r.CONSTRAINT_NAME = k.CONSTRAINT_NAME "
            + "WHERE k.TABLE_SCHEMA = '\(dbLit)' AND k.TABLE_NAME = '\(tblLit)' AND k.REFERENCED_TABLE_NAME IS NOT NULL "
            + "AND r.CONSTRAINT_SCHEMA = '\(dbLit)' AND r.TABLE_NAME = '\(tblLit)' "
            + "GROUP BY k.CONSTRAINT_NAME, k.REFERENCED_TABLE_NAME, r.DELETE_RULE, r.UPDATE_RULE "
            + "ORDER BY k.CONSTRAINT_NAME"
    }

    /// Triggers via SHOW TRIGGERS — reads cached trigger definitions, always fast.
    func fetchTriggersMySQL(alias: String, database: String, table: String) async throws -> [[String]] {
        let dbEsc  = database.replacingOccurrences(of: "`", with: "``")
        let tblEsc = table.replacingOccurrences(of: "'", with: "''")
        let aliEsc = alias.replacingOccurrences(of: "'", with: "''")
        // SHOW TRIGGERS FROM db WHERE `Table` = 'name' — MySQL filters at source, instant
        let sql = "SELECT * FROM mysql_query('\(aliEsc)', 'SHOW TRIGGERS FROM `\(dbEsc)` WHERE `Table` = ''\(tblEsc)''')"
        guard let result = try? await metaQuery(sql) else { return [] }
        // SHOW TRIGGERS columns: Trigger(0) Event(1) Table(2) Statement(3) Timing(4) Created(5) ... Definer(7)
        return result.rows.map { r in
            let trigger   = r.count > 0 ? r[0] : ""
            let event     = r.count > 1 ? r[1] : ""
            let statement = r.count > 3 ? r[3] : ""
            let timing    = r.count > 4 ? r[4] : ""
            let created   = r.count > 5 ? r[5] : ""
            let definer   = r.count > 7 ? r[7] : ""
            return [trigger, timing, event, definer, statement, created]
        }
    }

    func fetchColumnsMySQL(alias: String, database: String, table: String) async throws -> [ColumnInfo] {
        // Use SHOW FULL COLUMNS via mysql_query() — returns real MySQL types (varchar(10) not just
        // VARCHAR), key types, collation, defaults and comments. duckdb_constraints() does NOT
        // get populated with MySQL PRIMARY KEY data, so this is the only reliable approach.
        let aliEsc = alias.replacingOccurrences(of: "'", with: "''")
        let dbEsc  = database.replacingOccurrences(of: "`", with: "``")
        let tblEsc = table.replacingOccurrences(of: "`", with: "``")

        let colSQL = "SELECT * FROM mysql_query('\(aliEsc)', 'SHOW FULL COLUMNS FROM `\(dbEsc)`.`\(tblEsc)`')"
        let colResult = try await metaQuery(colSQL)

        // SHOW INDEX WHERE Key_name = PRIMARY — SHOW FULL COLUMNS only marks the FIRST column
        // of a composite PK as PRI; this query gets ALL columns in the primary key.
        let pkSQL = "SELECT * FROM mysql_query('\(aliEsc)', 'SHOW INDEX FROM `\(dbEsc)`.`\(tblEsc)` WHERE Key_name = ''PRIMARY''')"
        let pkResult = try? await metaQuery(pkSQL)
        // SHOW INDEX column 4 = Column_name
        let pkSet = Set(pkResult?.rows.compactMap { r -> String? in r.count > 4 ? r[4] : nil } ?? [])

        // SHOW FULL COLUMNS: 0:Field 1:Type 2:Collation 3:Null 4:Key 5:Default 6:Extra 7:Privileges 8:Comment
        return colResult.rows.compactMap { row -> ColumnInfo? in
            guard row.count >= 7, !row[0].isEmpty else { return nil }
            let name      = row[0]
            let type      = row[1]                         // full MySQL type e.g. "varchar(10)"
            let collation = row[2]
            let nullable  = row[3].uppercased() == "YES"
            var keyType   = row[4]                         // PRI/UNI/MUL/"" from MySQL
            let defaultV  = row[5]
            let extra     = row[6]
            let comment   = row.count > 8 ? row[8] : ""
            let encoding  = collation.components(separatedBy: "_").first ?? ""
            // Override: all PK columns (including non-first in composite PK) → PRI
            if pkSet.contains(name) { keyType = "PRI" }
            return ColumnInfo(
                id: "\(table).\(name)", name: name, dataType: type,
                nullable: nullable, keyType: keyType,
                defaultValue: defaultV, extra: extra,
                encoding: encoding, collation: collation, comment: comment
            )
        }
    }

    /// Converts a DuckDB type name + length/precision into a MySQL-style display string.
    private static func mysqlTypeDisplay(_ duck: String, charLen: Int, numPrec: Int, numScale: Int) -> String {
        // If type already carries parameters (e.g. DECIMAL(10,2)) return as-is lowercased
        if duck.contains("(") { return duck.lowercased() }
        switch duck.uppercased() {
        case "VARCHAR", "CHAR":
            return charLen > 0 ? "\(duck.lowercased())(\(charLen))" : duck.lowercased()
        case "DECIMAL", "NUMERIC":
            if numPrec > 0 && numScale > 0 { return "decimal(\(numPrec),\(numScale))" }
            if numPrec > 0 { return "decimal(\(numPrec))" }
            return "decimal"
        case "INTEGER":  return "int"
        case "TIMESTAMP", "TIMESTAMP WITH TIME ZONE": return "datetime"
        case "BOOLEAN":  return "tinyint(1)"
        default:         return duck.lowercased()
        }
    }

    func fetchIndexesMySQL(alias: String, database: String, table: String) async throws -> [IndexInfo] {
        // SHOW INDEX via mysql_query() — gets ALL MySQL indexes (PRIMARY, UNIQUE, regular, FULLTEXT).
        // duckdb_constraints() is unreliable for MySQL-attached databases as mysql_scanner
        // does not always populate constraint metadata from MySQL.
        let aliEsc = alias.replacingOccurrences(of: "'", with: "''")
        let dbEsc  = database.replacingOccurrences(of: "`", with: "``")
        let tblEsc = table.replacingOccurrences(of: "`", with: "``")
        let sql    = "SELECT * FROM mysql_query('\(aliEsc)', 'SHOW INDEX FROM `\(dbEsc)`.`\(tblEsc)`')"
        guard let result = try? await metaQuery(sql), !result.rows.isEmpty else { return [] }

        // SHOW INDEX columns:
        // 0:Table  1:Non_unique  2:Key_name  3:Seq_in_index  4:Column_name
        // 5:Collation  6:Cardinality  7:Sub_part  8:Packed  9:Null  10:Index_type  11:Comment
        struct Entry { var unique: Bool; var cols: [(Int, String)]; var indexType: String }
        var order: [String] = []
        var map: [String: Entry] = [:]

        for row in result.rows where row.count >= 5 {
            let keyName   = row[2]
            let nonUnique = row[1] == "1"
            let seqIdx    = Int(row[3]) ?? 0
            let colName   = row[4]
            let idxType   = row.count > 10 ? row[10] : "BTREE"
            if map[keyName] == nil { order.append(keyName); map[keyName] = Entry(unique: !nonUnique, cols: [], indexType: idxType) }
            map[keyName]!.cols.append((seqIdx, colName))
        }
        return order.compactMap { key -> IndexInfo? in
            guard let entry = map[key] else { return nil }
            let sortedCols = entry.cols.sorted { $0.0 < $1.0 }.map { $0.1 }
            return IndexInfo(id: "\(table).\(key)", name: key,
                             columns: sortedCols, unique: entry.unique, indexType: entry.indexType)
        }
    }

    /// Parses a DuckDB LIST cast to VARCHAR, e.g. "[col1, col2]" or "col1"
    private func parseListString(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") && t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
        return t.components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "NULL" }
    }

    // MARK: - Private: column extraction

    /// Renders a BLOB value for display.
    ///
    /// MySQL hands back much of its `SHOW …` metadata with a binary collation, and
    /// mysql_scanner surfaces those columns as DuckDB BLOBs — so table names, column
    /// types and trigger bodies all arrive here. Text-like bytes must come back as
    /// text; genuinely binary payloads stay hex.
    nonisolated static func decodeBlob(_ data: Data) -> String {
        // Lowercase hex via a digit table — String(format:) per byte was the slow way.
        let hex = { () -> String in
            let digits = Array("0123456789abcdef".utf8)
            var out = [UInt8](); out.reserveCapacity(data.count * 2)
            for b in data { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0x0F)]) }
            return String(decoding: out, as: UTF8.self)
        }
        guard let text = String(data: data, encoding: .utf8) else { return hex() }
        // NUL and other C0 controls never appear in MySQL metadata, but do appear in
        // real binary that happens to decode as UTF-8. Tab/newline/return are text.
        let isBinary = text.unicodeScalars.contains { scalar in
            scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r"
        }
        return isBinary ? hex() : text
    }

    /// Returns each cell as `String?` — nil means SQL NULL (distinct from the
    /// literal string "NULL"). Callers assemble display rows + a null mask from this.
    /// One CellTable chunk from the data chunks of a streaming pull.
    nonisolated static func cellChunk(pieces: [ResultChunk], columnCount: Int) -> CellTable.Chunk {
        let rowCount = pieces.reduce(0) { $0 + $1.rowCount }
        var colData: [[String?]] = []
        colData.reserveCapacity(columnCount)
        for ci in 0..<columnCount {
            var column: [String?] = []
            column.reserveCapacity(rowCount)
            for piece in pieces { column.append(contentsOf: extractColumn(piece, colIndex: ci, rowRange: 0..<piece.rowCount)) }
            colData.append(column)
        }
        return CellTable.Chunk(columns: colData, rowCount: rowCount)
    }

    /// One CellTable chunk from a row range of a materialized result.
    nonisolated static func cellChunk(materialized rs: ResultSet, rows: Range<Int>, columnCount: Int) -> CellTable.Chunk {
        CellTable.Chunk(columns: (0..<columnCount).map { extractColumn(rs, colIndex: $0, rowRange: rows) }, rowCount: rows.count)
    }

    nonisolated static func extractColumn<S: BulkColumnSource>(_ rs: S, colIndex: Int, rowRange: Range<Int>) -> [String?] {
        let col = DBInt(colIndex)
        let dbType = rs.columnStorageType(at: col)
        let rows = DBInt(rowRange.lowerBound)..<DBInt(rowRange.upperBound)

        // Chunk-sequential bulk reads (vendor/DuckDB ResultSet+Bulk, a local patch): one
        // vector per data chunk instead of a vector, a logical type and an element box
        // per cell. The per-cell path cost ~8µs a cell — wide results streamed at
        // ~125k cells/s, minutes for a million rows. Values render exactly as before.
        switch dbType {
        case .varchar:
            return rs.bulk(String.self, column: col, rows: rows)
        case .uuid:
            return rs.bulk(UUID.self, column: col, rows: rows).map { $0.map { $0.uuidString } }
        case .boolean:
            return rs.bulk(Bool.self, column: col, rows: rows).map { $0.map(String.init) }
        case .tinyint:
            return rs.bulk(Int8.self, column: col, rows: rows).map { $0.map(String.init) }
        case .smallint:
            return rs.bulk(Int16.self, column: col, rows: rows).map { $0.map(String.init) }
        case .integer:
            return rs.bulk(Int32.self, column: col, rows: rows).map { $0.map(String.init) }
        case .bigint:
            return rs.bulk(Int64.self, column: col, rows: rows).map { $0.map(String.init) }
        case .hugeint:
            return rs.bulk(IntHuge.self, column: col, rows: rows).map { $0.map { String(describing: $0) } }
        case .utinyint:
            return rs.bulk(UInt8.self, column: col, rows: rows).map { $0.map(String.init) }
        case .usmallint:
            return rs.bulk(UInt16.self, column: col, rows: rows).map { $0.map(String.init) }
        case .uinteger:
            return rs.bulk(UInt32.self, column: col, rows: rows).map { $0.map(String.init) }
        case .ubigint:
            return rs.bulk(UInt64.self, column: col, rows: rows).map { $0.map(String.init) }
        case .uhugeint:
            return rs.bulk(UIntHuge.self, column: col, rows: rows).map { $0.map { String(describing: $0) } }
        case .float:
            return rs.bulk(Float.self, column: col, rows: rows).map { $0.map { String($0) } }
        case .double:
            return rs.bulk(Double.self, column: col, rows: rows).map { $0.map { String($0) } }
        case .decimal:
            return rs.bulk(Decimal.self, column: col, rows: rows).map { $0.map { String(describing: $0) } }
        case .date:
            // DuckDB's Date is its own type (days since epoch), not Foundation.Date
            return rs.bulk(DuckDB.Date.self, column: col, rows: rows).map { $0.map { formatDuckDBDate($0) } }
        case .timestamp, .timestampS, .timestampMS, .timestampNS, .timestampTz:
            return rs.bulk(Timestamp.self, column: col, rows: rows).map { $0.map { formatTimestamp($0) } }
        case .time:
            return rs.bulk(Time.self, column: col, rows: rows).map { $0.map { Self.formatTime($0) } }
        case .timeTz:
            return rs.bulk(TimeTz.self, column: col, rows: rows).map { $0.map { Self.formatTimeTz($0) } }
        case .enum:
            return rs.bulk(String.self, column: col, rows: rows)
        case .blob:
            return rs.bulk(Data.self, column: col, rows: rows).map { $0.map { Self.decodeBlob($0) } }
        case .interval:
            return rs.bulk(Interval.self, column: col, rows: rows).map { $0.map { Self.formatInterval($0) } }
        default:
            // Fallback: attempt String cast; unsupported/complex types show NULL
            return rs.bulk(String.self, column: col, rows: rows)
        }
    }

    /// Zero-padded decimal: zeroPadded(7, width: 2) == "07". Pure Swift. The cell
    /// formatters call this once per timestamp/date/time cell; Foundation's
    /// String(format:) — which validates and parses its format string on every call —
    /// was a quarter of the streaming extraction cost on a wide result. Never
    /// truncates a value wider than the field. Non-negative values only.
    nonisolated static func zeroPadded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        let pad = width - digits.utf8.count
        return pad > 0 ? String(repeating: "0", count: pad) + digits : digits
    }

    /// Four-digit ISO year ("0987"); a BC year keeps its sign as DuckDB sends it.
    nonisolated private static func isoYear(_ year: Int) -> String {
        year < 0 ? String(year) : zeroPadded(year, width: 4)
    }

    nonisolated private static func formatDuckDBDate(_ date: DuckDB.Date) -> String {
        let c = date.components
        return "\(isoYear(Int(c.year)))-\(zeroPadded(Int(c.month), width: 2))-\(zeroPadded(Int(c.day), width: 2))"
    }

    nonisolated static func formatTimestamp(_ ts: Timestamp) -> String {
        let c = ts.components
        let datePart = "\(isoYear(Int(c.date.year)))-\(zeroPadded(Int(c.date.month), width: 2))-\(zeroPadded(Int(c.date.day), width: 2))"
        let timePart = clock(hour: Int(c.time.hour), minute: Int(c.time.minute),
                             second: Int(c.time.second), microsecond: Int(c.time.microsecond))
        return "\(datePart) \(timePart)"
    }

    /// HH:MM:SS, with a trimmed .ffffff fraction only when microseconds are present.
    nonisolated static func clock(hour: Int, minute: Int, second: Int, microsecond: Int) -> String {
        var s = "\(zeroPadded(hour, width: 2)):\(zeroPadded(minute, width: 2)):\(zeroPadded(second, width: 2))"
        if microsecond != 0 {
            var frac = zeroPadded(microsecond, width: 6)
            while frac.hasSuffix("0") { frac.removeLast() }
            s += "." + frac
        }
        return s
    }

    nonisolated static func formatTime(_ t: Time) -> String {
        let c = t.components
        return clock(hour: Int(c.hour), minute: Int(c.minute), second: Int(c.second), microsecond: Int(c.microsecond))
    }

    nonisolated static func formatTimeTz(_ t: TimeTz) -> String {
        formatTime(t.time) + zoneOffset(seconds: Int(t.offset))
    }

    nonisolated static func formatInterval(_ iv: Interval) -> String {
        intervalString(months: Int(iv.months), days: Int(iv.days), microseconds: iv.microseconds)
    }

    /// ISO-style zone suffix: "+00", "+05:30", "-08". Pure/testable.
    nonisolated static func zoneOffset(seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return m == 0 ? "\(sign)\(zeroPadded(h, width: 2))"
                      : "\(sign)\(zeroPadded(h, width: 2)):\(zeroPadded(m, width: 2))"
    }

    /// DuckDB-style interval, e.g. "1 year 2 months 3 days 04:05:06.5". Pure/testable.
    nonisolated static func intervalString(months: Int, days: Int, microseconds: Int64) -> String {
        var parts: [String] = []
        if months != 0 {
            let years = months / 12, rem = months % 12
            if years != 0 { parts.append("\(years) year\(abs(years) == 1 ? "" : "s")") }
            if rem != 0 { parts.append("\(rem) month\(abs(rem) == 1 ? "" : "s")") }
        }
        if days != 0 { parts.append("\(days) day\(abs(days) == 1 ? "" : "s")") }
        if microseconds != 0 || parts.isEmpty {
            let neg = microseconds < 0
            var m = abs(microseconds)
            let hours = m / 3_600_000_000; m %= 3_600_000_000
            let mins  = m / 60_000_000;    m %= 60_000_000
            let secs  = m / 1_000_000
            let frac  = m % 1_000_000
            var t = "\(neg ? "-" : "")\(zeroPadded(Int(hours), width: 2)):\(zeroPadded(Int(mins), width: 2)):\(zeroPadded(Int(secs), width: 2))"
            if frac != 0 {
                var f = zeroPadded(Int(frac), width: 6)
                while f.hasSuffix("0") { f.removeLast() }
                t += "." + f
            }
            parts.append(t)
        }
        return parts.joined(separator: " ")
    }
}
// MARK: - Cell sources

/// What result extraction needs from a source of cells: a whole materialized result
/// (`ResultSet`) or one chunk of a streaming one (`ResultChunk`). Both offer the
/// vendored bulk readers; only the column type lookup is spelled differently.
nonisolated protocol BulkColumnSource {
    func columnStorageType(at index: DBInt) -> DatabaseType
    func bulk(_ type: String.Type,    column: DBInt, rows: Range<DBInt>) -> [String?]
    func bulk(_ type: Bool.Type,      column: DBInt, rows: Range<DBInt>) -> [Bool?]
    func bulk(_ type: Int8.Type,      column: DBInt, rows: Range<DBInt>) -> [Int8?]
    func bulk(_ type: Int16.Type,     column: DBInt, rows: Range<DBInt>) -> [Int16?]
    func bulk(_ type: Int32.Type,     column: DBInt, rows: Range<DBInt>) -> [Int32?]
    func bulk(_ type: Int64.Type,     column: DBInt, rows: Range<DBInt>) -> [Int64?]
    func bulk(_ type: UInt8.Type,     column: DBInt, rows: Range<DBInt>) -> [UInt8?]
    func bulk(_ type: UInt16.Type,    column: DBInt, rows: Range<DBInt>) -> [UInt16?]
    func bulk(_ type: UInt32.Type,    column: DBInt, rows: Range<DBInt>) -> [UInt32?]
    func bulk(_ type: UInt64.Type,    column: DBInt, rows: Range<DBInt>) -> [UInt64?]
    func bulk(_ type: Float.Type,     column: DBInt, rows: Range<DBInt>) -> [Float?]
    func bulk(_ type: Double.Type,    column: DBInt, rows: Range<DBInt>) -> [Double?]
    func bulk(_ type: IntHuge.Type,   column: DBInt, rows: Range<DBInt>) -> [IntHuge?]
    func bulk(_ type: UIntHuge.Type,  column: DBInt, rows: Range<DBInt>) -> [UIntHuge?]
    func bulk(_ type: UUID.Type,      column: DBInt, rows: Range<DBInt>) -> [UUID?]
    func bulk(_ type: Time.Type,      column: DBInt, rows: Range<DBInt>) -> [Time?]
    func bulk(_ type: TimeTz.Type,    column: DBInt, rows: Range<DBInt>) -> [TimeTz?]
    func bulk(_ type: DuckDB.Date.Type, column: DBInt, rows: Range<DBInt>) -> [DuckDB.Date?]
    func bulk(_ type: Interval.Type,  column: DBInt, rows: Range<DBInt>) -> [Interval?]
    func bulk(_ type: Timestamp.Type, column: DBInt, rows: Range<DBInt>) -> [Timestamp?]
    func bulk(_ type: Data.Type,      column: DBInt, rows: Range<DBInt>) -> [Data?]
    func bulk(_ type: Decimal.Type,   column: DBInt, rows: Range<DBInt>) -> [Decimal?]
}

extension ResultSet: BulkColumnSource {
    nonisolated func columnStorageType(at index: DBInt) -> DatabaseType { self[index].underlyingDatabaseType }
}

extension ResultChunk: BulkColumnSource {
    nonisolated func columnStorageType(at index: DBInt) -> DatabaseType { columnDataType(at: index) }
}

/// Import SQL file: the statement that failed (1-based) and why.
nonisolated struct SQLScriptFailure: Error, LocalizedError {
    let index: Int
    let total: Int
    let reason: String
    var errorDescription: String? { "Statement \(index) of \(total): \(reason)" }
}
