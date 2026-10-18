//
//  ConnectionTypeTests.swift
//  SequelBridgeTests
//
//  Every connection type the form offers, on every engine that offers it, against the
//  local test servers. SSH goes through the test SSH server (scripts/fixtures/ssh) to
//  databases addressed as host.docker.internal, a name only the SSH server can resolve,
//  so a test can only pass through the tunnel. Sockets go through the Unix-socket relay
//  (scripts/fixtures/socket-relay.py). Gated: SB_SSH_VERIFY=1 with SB_SSH_KEY for SSH,
//  SB_SOCKET_VERIFY=1 for sockets; scripts/run-all-tests.sh sets both.
//

import AppKit
import Foundation
import Testing
@testable import SequelBridge

private enum CTEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var ssh: Bool { e["SB_SSH_VERIFY"] == "1" && !(e["SB_SSH_KEY"] ?? "").isEmpty }
    static var sockets: Bool { e["SB_SOCKET_VERIFY"] == "1" }
    static var key: String { e["SB_SSH_KEY"] ?? "" }
    static var sshPort: Int { Int(e["SB_SSH_PORT"] ?? "") ?? 2224 }
    static var dockerHost: String { e["SB_SSH_DB_HOST"] ?? "host.docker.internal" }
    static var mysqlSocket: String { e["SB_MYSQL_SOCKET"] ?? "/tmp/sb-sock/mysql.sock" }
    static var pgSocketDir: String { e["SB_PG_SOCKET_DIR"] ?? "/tmp/sb-sock" }
}

@Suite("Connection types: which engine offers which")
struct ConnectionTypeOfferTests {
    @Test("MySQL and PostgreSQL offer TCP/IP, SSH and Socket; ClickHouse TCP/IP and SSH; a SQLite file none")
    func offered() {
        #expect(DatabaseEngine.mysql.connectionTypes == [.tcpip, .ssh, .socket])
        #expect(DatabaseEngine.postgres.connectionTypes == [.tcpip, .ssh, .socket])
        #expect(DatabaseEngine.clickhouse.connectionTypes == [.tcpip, .ssh])
        #expect(DatabaseEngine.sqlite.connectionTypes.isEmpty)
    }

    @Test("a PostgreSQL socket is a directory plus the port, given as either the directory or the socket file")
    func postgresSocketDSN() {
        var c = Connection(name: "p", alias: "p", connectionType: .socket, port: 5433,
                           username: "u", database: "d", socketPath: "/tmp/sock", engine: .postgres)
        #expect(QueryEngine.buildDSN(for: c, password: "", socket: c.socketPath) == "host=/tmp/sock port=5433 user=u dbname=d")
        c.socketPath = "/var/run/postgresql/.s.PGSQL.5432"
        #expect(QueryEngine.buildDSN(for: c, password: "", socket: c.socketPath) == "host=/var/run/postgresql port=5432 user=u dbname=d")
        c.engine = .mysql
        c.socketPath = "/tmp/mysql.sock"
        #expect(QueryEngine.buildDSN(for: c, password: "", socket: c.socketPath) == "socket=/tmp/mysql.sock user=u database=d")
    }

    @Test("plain HTTP may go to any server: ClickHouse's HTTP interface is often reached by host name without TLS")
    func transportSecurityAllowsServers() {
        // Without it, App Transport Security refuses http:// to every host name (an IP
        // address is exempt), so a ClickHouse server by name could not connect at all.
        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        #expect(ats?["NSAllowsArbitraryLoads"] as? Bool == true)
    }

    @Test("the form starts each engine at its usual socket: MySQL's file, PostgreSQL's directory")
    func defaultSocketPaths() {
        #expect(DatabaseEngine.mysql.defaultSocketPath == "/tmp/mysql.sock")
        #expect(DatabaseEngine.postgres.defaultSocketPath == "/tmp")
    }
}

@MainActor
@Suite("Connection types: end to end", .serialized)
struct ConnectionTypeTests {
    // The fixture logins of scripts/run-all-tests.sh.
    static let mysqlPass = "sbverify123", pgPass = "sbpass123", chPass = "sbpass123"

    func viaSSH(_ engine: DatabaseEngine, alias: String, port: Int, user: String, database: String) -> Connection {
        Connection(name: alias, alias: alias, connectionType: .ssh, host: CTEnv.dockerHost, port: port,
                   username: user, database: database, sshHost: "127.0.0.1", sshPort: CTEnv.sshPort,
                   sshUsername: "tunneluser", sshKeyPath: CTEnv.key, engine: engine)
    }

    /// The ssh tunnel processes running now whose forward spec contains `text`.
    func tunnelProcesses(matching text: String) -> Int {
        processes(matching: "ssh -N -L [0-9]+\(NSRegularExpression.escapedPattern(for: text)) ")
    }

    /// The processes running now whose command line matches `regex`.
    func processes(matching regex: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", regex]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").count
    }

    @Test("PostgreSQL through an SSH tunnel", .enabled(if: CTEnv.ssh))
    func postgresOverSSH() async throws {
        let engine = try QueryEngine()
        try await engine.attach(viaSSH(.postgres, alias: "sshpg", port: 5433, user: "sbuser", database: "sbtest"),
                                password: Self.pgPass)
        defer { Task { try? await engine.detach("sshpg") } }
        let r = try await engine.query("SELECT COUNT(*) FROM \"sshpg\".\"public\".\"customers\"")
        #expect(r.rows.first?.first == "3")
    }

    @Test("ClickHouse through an SSH tunnel", .enabled(if: CTEnv.ssh))
    func clickhouseOverSSH() async throws {
        let engine = try QueryEngine()
        try await engine.attach(viaSSH(.clickhouse, alias: "sshch", port: 8123, user: "sbuser", database: "default"),
                                password: Self.chPass)
        let r = try await engine.clickhouseQuery(alias: "sshch", sql: "SELECT count() FROM default.events")
        #expect(r.rows.first?.first == "3")
        let pattern = ":\(CTEnv.dockerHost):8123"           // only ClickHouse is forwarded to 8123
        #expect(tunnelProcesses(matching: pattern) == 1)
        try await engine.detach("sshch")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(tunnelProcesses(matching: pattern) == 0, "detaching ClickHouse must close its tunnel")
    }

    @Test("MySQL through an SSH tunnel: EXPLAIN on the built-in client goes through the tunnel too", .enabled(if: CTEnv.ssh))
    func mysqlExplainOverSSH() async throws {
        let engine = try QueryEngine()
        try await engine.attach(viaSSH(.mysql, alias: "sshmy", port: 3309, user: "root", database: "sbtest"),
                                password: Self.mysqlPass)
        defer { Task { try? await engine.detach("sshmy") } }
        let plan = try await engine.explain(alias: "sshmy", serverSQL: "SELECT * FROM customers WHERE id = 1")
        #expect(plan.rowCount >= 1)
    }

    @Test("Test Connection over SSH succeeds and leaves no tunnel behind", .enabled(if: CTEnv.ssh))
    func testConnectionClosesTunnel() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sb_ct_\(UUID().uuidString)")
        let manager = try ConnectionManager(arguments: ["app", "-SBSupportDir", support.path])
        // A forward target no other test uses (the same host, written as a fully
        // qualified name), so only this tunnel's ssh process can match.
        var c = viaSSH(.mysql, alias: "sshtest", port: 3309, user: "root", database: "sbtest")
        c.host = CTEnv.dockerHost + "."
        let pattern = ":" + c.host + ":3309"
        #expect(tunnelProcesses(matching: pattern) == 0)
        let error = await manager.testConnection(c, password: Self.mysqlPass)
        #expect(error == nil, "Test Connection failed: \(error ?? "")")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(tunnelProcesses(matching: pattern) == 0, "Test Connection left its tunnel running")
    }

    @Test("quitting the app closes every SSH tunnel it opened", .enabled(if: CTEnv.ssh))
    func quitClosesTunnels() async throws {
        // Before this, a tunnel's ssh process outlived the app: reparented to launchd, it
        // kept the SSH session and the local port open until the server went away.
        let tunnel = SSHTunnel()
        try await tunnel.start(conn: viaSSH(.mysql, alias: "sshquit", port: 3309, user: "root", database: "sbtest"))
        let mine = "^/usr/bin/ssh -N -L \(tunnel.localPort):"
        #expect(processes(matching: mine) == 1)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApplication.shared)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(processes(matching: mine) == 0, "the tunnel's ssh process outlived the app")
        tunnel.stop()
    }

    @Test("SSH with a user the server does not know fails fast and says why", .enabled(if: CTEnv.ssh))
    func sshUnknownUserFails() async throws {
        let engine = try QueryEngine()
        var c = viaSSH(.mysql, alias: "sshnouser", port: 3309, user: "root", database: "sbtest")
        c.sshUsername = "nobody"
        let started = Date()
        do {
            try await engine.attach(c, password: Self.mysqlPass)
            Issue.record("attach succeeded for an unknown SSH user")
        } catch {
            #expect(QueryEngine.extractReason(from: error).contains("Permission denied"))
        }
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test("MySQL over a Unix socket: queries and EXPLAIN", .enabled(if: CTEnv.sockets))
    func mysqlOverSocket() async throws {
        let engine = try QueryEngine()
        let c = Connection(name: "sockmy", alias: "sockmy", connectionType: .socket, username: "root",
                           database: "sbtest", socketPath: CTEnv.mysqlSocket, engine: .mysql)
        try await engine.attach(c, password: Self.mysqlPass)
        defer { Task { try? await engine.detach("sockmy") } }
        let r = try await engine.query("SELECT COUNT(*) FROM \"sockmy\".\"sbtest\".\"customers\"")
        #expect(r.rows.first?.first == "3")
        let plan = try await engine.explain(alias: "sockmy", serverSQL: "SELECT * FROM customers WHERE id = 1")
        #expect(plan.rowCount >= 1)
    }

    @Test("PostgreSQL over a Unix socket, given as the directory or as the socket file", .enabled(if: CTEnv.sockets))
    func postgresOverSocket() async throws {
        for (alias, path) in [("sockpgdir", CTEnv.pgSocketDir), ("sockpgfile", CTEnv.pgSocketDir + "/.s.PGSQL.5433")] {
            let engine = try QueryEngine()
            let c = Connection(name: alias, alias: alias, connectionType: .socket, port: 5433, username: "sbuser",
                               database: "sbtest", socketPath: path, engine: .postgres)
            try await engine.attach(c, password: Self.pgPass)
            let r = try await engine.query("SELECT COUNT(*) FROM \"\(alias)\".\"public\".\"customers\"")
            #expect(r.rows.first?.first == "3", "\(path)")
            try await engine.detach(alias)
        }
    }

    @Test("ClickHouse refuses a socket connection with a clear message")
    func clickhouseSocketRefused() async throws {
        let engine = try QueryEngine()
        let c = Connection(name: "sockch", alias: "sockch", connectionType: .socket, host: "127.0.0.1", port: 8123,
                           username: "sbuser", database: "default", engine: .clickhouse)
        do {
            try await engine.attach(c, password: Self.chPass)
            Issue.record("a ClickHouse socket connection was accepted")
        } catch {
            #expect(QueryEngine.extractReason(from: error).contains("socket"))
        }
    }
}
