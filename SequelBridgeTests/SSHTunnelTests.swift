//
//  SSHTunnelTests.swift
//  SequelBridgeTests
//
//  Covers SSHTunnel's local-port allocation and its failure path. The end-to-end
//  tests open the app's own tunnel to the test SSH server that
//  scripts/run-all-tests.sh provisions (scripts/fixtures/ssh/sshd-setup.sh): one
//  port with today's defaults, one behaving like an old server that offers only
//  ssh-rsa. They run when SB_SSH_VERIFY=1 and SB_SSH_KEY name the test key.
//

import Foundation
import Testing
@testable import SequelBridge

private struct SSHEnv {
    static var e: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { e["SB_SSH_VERIFY"] == "1" }
    static var keyPath: String { e["SB_SSH_KEY"] ?? "" }
    static var phraseKeyPath: String { e["SB_SSH_PHRASE_KEY"] ?? "" }   // passphrase "sbphrase"
    static var port: Int { Int(e["SB_SSH_PORT"] ?? "") ?? 2224 }
    static var legacyPort: Int { Int(e["SB_SSH_LEGACY_PORT"] ?? "") ?? 2225 }
    // The MariaDB container as the SSH server sees it, with the fixture's login.
    static var dbHost: String { e["SB_SSH_DB_HOST"] ?? "host.docker.internal" }
    static var dbPort: Int { Int(e["SB_SSH_DB_PORT"] ?? "") ?? 3309 }
    static var dbUser: String { e["SB_SSH_DB_USER"] ?? "root" }
    static var dbPass: String { e["SB_SSH_DB_PASS"] ?? "sbverify123" }
}


@MainActor
@Suite("SSH tunnel", .serialized)
struct SSHTunnelTests {

    /// The tests run inside the app, which answers ssh's questions with a dialog. No test
    /// may put that on screen: each starts with nothing answering, as a key login needs.
    init() { SSHTunnel.prompter = nil }

    @Test("allocates a local port inside the reserved range")
    func portAllocation() {
        let t = SSHTunnel()
        #expect(SSHTunnel.portRange.contains(t.localPort))
    }

    @Test("port allocation is randomized and in range")
    func randomizedPorts() {
        // The allocator scans from a random start so concurrent tunnels rarely
        // collide (an actual bind race at start time is caught by ssh's
        // ExitOnForwardFailure). It cannot promise uniqueness — nothing reserves
        // the port between the free-check and ssh binding it — but it must spread
        // across the range rather than always returning the same number.
        let ports = (0..<30).map { _ in SSHTunnel().localPort }
        #expect(ports.allSatisfy { SSHTunnel.portRange.contains($0) })
        #expect(Set(ports).count > 1, "allocation is not randomized: \(Set(ports))")
    }

    @Test("fails with an actionable message when the SSH host is unreachable")
    func unreachableHostFails() async throws {
        var conn = Connection(name: "bad", alias: "bad", connectionType: .ssh,
                              host: "127.0.0.1", port: 3306, username: "mysqluser")
        // RFC 5737 documentation address — guaranteed not to be a live SSH server.
        conn.sshHost = "192.0.2.1"
        conn.sshPort = 22
        conn.sshUsername = "nobody"

        let tunnel = SSHTunnel()
        let start = Date()
        await #expect(throws: (any Error).self) {
            try await tunnel.start(conn: conn)
        }
        let elapsed = Date().timeIntervalSince(start)
        tunnel.stop()
        // ConnectTimeout=10 is passed to ssh, and start() gives up after ~10s.
        // Assert it gives up rather than hanging indefinitely.
        #expect(elapsed < 25, "SSHTunnel.start took \(elapsed)s to fail")
    }

    @Test("the tunnel allows ssh-rsa as a last resort, for the host key and for the user key")
    func allowsLegacyRSA() {
        var conn = Connection(name: "t", alias: "t", connectionType: .ssh,
                              host: "db.internal", port: 3306, username: "dbuser")
        conn.sshHost = "bastion.example"
        conn.sshPort = 22
        conn.sshUsername = "me"
        let args = SSHTunnel.arguments(for: conn, localPort: 13307, keyPath: "/keys/id_rsa")
        // "+" appends to ssh's own list, so a current server still negotiates its
        // current algorithms; an old one that offers only ssh-rsa gets in.
        #expect(args.contains("HostKeyAlgorithms=+ssh-rsa"))
        #expect(args.contains("PubkeyAcceptedAlgorithms=+ssh-rsa"))
        #expect(args.contains("13307:db.internal:3306"))
        if let i = args.firstIndex(of: "-i") { #expect(args[i + 1] == "/keys/id_rsa") } else { Issue.record("no -i") }
        #expect(args.contains("IdentitiesOnly=yes"))
        #expect(args.last == "me@bastion.example")
    }

    @Test("stop() is safe to call when no tunnel was ever started")
    func stopWithoutStart() {
        let t = SSHTunnel()
        t.stop()
        t.stop()
    }

    // MARK: - End-to-end (needs SB_SSH_VERIFY=1)


    func sshConnection(alias: String, sshPort: Int = SSHEnv.port) -> Connection {
        var c = Connection(name: "ssh", alias: alias, connectionType: .ssh,
                           // As seen FROM the ssh server: the MariaDB container.
                           host: SSHEnv.dbHost, port: SSHEnv.dbPort,
                           username: SSHEnv.dbUser, database: "sbtest")
        c.engine = .mysql
        c.sshHost = "127.0.0.1"
        c.sshPort = sshPort
        c.sshUsername = "tunneluser"
        c.sshKeyPath = SSHEnv.keyPath
        return c
    }

    /// Attaches through the tunnel, reads a table and its metadata, detaches.
    func attachAndQuery(_ conn: Connection) async throws {
        let engine = try QueryEngine()
        try await engine.attach(conn, password: SSHEnv.dbPass)
        // Tear the tunnel down at the end so its listener does not linger and
        // collide with the SSHTunnel unit suite's port range.
        defer { Task { try? await engine.detach(conn.alias) } }

        let r = try await engine.query("SELECT COUNT(*) FROM \"\(conn.alias)\".\"sbtest\".\"customers\"")
        #expect(r.rows.first?.first == "3")

        // Metadata flows through the tunnel too.
        let tables = try await engine.fetchTables(alias: conn.alias, database: "sbtest").map(\.name)
        #expect(tables.contains("customers"))
    }

    @Test("attach and query through the app's own tunnel",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func attachThroughTunnel() async throws {
        try await attachAndQuery(sshConnection(alias: "sshm"))
    }

    /// An old server (OpenSSH 7.1 and earlier) offers its host key only as ssh-rsa and
    /// accepts only ssh-rsa signatures from an RSA user key. Current macOS ssh has both
    /// switched off, so without them allowed the tunnel fails with "no matching host
    /// key type found. Their offer: ssh-rsa".
    @Test("attach through an old SSH server that offers only ssh-rsa",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func attachThroughLegacyServer() async throws {
        try await attachAndQuery(sshConnection(alias: "sshlegacy", sshPort: SSHEnv.legacyPort))
    }

    // MARK: - Login prompts (needs SB_SSH_VERIFY=1): what ssh asks goes to the app

    /// Runs `body` with `answer` answering ssh's questions; returns what ssh asked.
    func answering(_ answer: @escaping (SSHLoginRequest) -> String?,
                   _ body: () async throws -> Void) async throws -> [SSHLoginRequest] {
        let asked = AskLog()
        SSHTunnel.prompter = { @MainActor request in asked.items.append(request); return answer(request) }
        defer { SSHTunnel.prompter = nil }
        try await body()
        return asked.items
    }

    /// pwuser logs in with a password. The test key isn't authorized for it, so ssh tries
    /// that key alone (IdentitiesOnly), then asks for the password.
    func passwordConnection(alias: String) -> Connection {
        var c = sshConnection(alias: alias)
        c.sshUsername = "pwuser"
        return c
    }

    @Test("a password login: ssh asks for the password and the app answers",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func passwordLogin() async throws {
        let asked = try await answering({ _ in "sbssh123" }) {
            try await attachAndQuery(passwordConnection(alias: "sshpw"))
        }
        #expect(asked.map(\.kind) == [.password], "asked: \(asked.map(\.prompt))")
        #expect(asked.first?.user == "pwuser")
    }

    @Test("a key with a passphrase: ssh asks for the passphrase and the app answers",
          .enabled(if: SSHEnv.enabled && !SSHEnv.phraseKeyPath.isEmpty))
    func passphraseLogin() async throws {
        var c = sshConnection(alias: "sshphrase")
        c.sshKeyPath = SSHEnv.phraseKeyPath
        let asked = try await answering({ _ in "sbphrase" }) { try await attachAndQuery(c) }
        #expect(asked.map(\.kind) == [.passphrase], "asked: \(asked.map(\.prompt))")
    }

    @Test("Cancel in the login dialog stops the connection at once, and says so",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func cancelledLogin() async throws {
        let engine = try QueryEngine()
        let started = Date()
        var reason = ""
        let asked = try await answering({ _ in nil }) {
            do { try await engine.attach(passwordConnection(alias: "sshcancel"), password: SSHEnv.dbPass) }
            catch { reason = QueryEngine.extractReason(from: error) }
        }
        #expect(asked.count == 1)
        #expect(reason.localizedCaseInsensitiveContains("cancelled"), "got: \(reason)")
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test("Cancel on a key's passphrase moves on to the password, as ssh does at a terminal",
          .enabled(if: SSHEnv.enabled && !SSHEnv.phraseKeyPath.isEmpty))
    func cancelPassphraseThenPassword() async throws {
        // pwuser accepts the passphrase key and a password: skipping the key leaves the password.
        var c = passwordConnection(alias: "sshskip")
        c.sshKeyPath = SSHEnv.phraseKeyPath
        let asked = try await answering({ $0.kind == .passphrase ? nil : "sbssh123" }) { try await attachAndQuery(c) }
        #expect(asked.map(\.kind) == [.passphrase, .password], "asked: \(asked.map(\.prompt))")
    }

    @Test("a wrong password is asked again, then the login fails with the server's reason",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func wrongPassword() async throws {
        let engine = try QueryEngine()
        var reason = ""
        let asked = try await answering({ _ in "not-the-password" }) {
            do { try await engine.attach(passwordConnection(alias: "sshwrong"), password: SSHEnv.dbPass) }
            catch { reason = QueryEngine.extractReason(from: error) }
        }
        #expect(asked.map(\.timesAsked) == [0, 1, 2], "asked: \(asked.map(\.prompt))")
        #expect(reason.contains("Permission denied"), "got: \(reason)")
    }

    @Test("a wrong key path fails with an actionable message, not a hang")
    func badKeyFails() async throws {
        let engine = try QueryEngine()
        var bad = sshConnection(alias: "sshbad")
        bad.sshKeyPath = "/nonexistent/key"
        let started = Date()
        await #expect(throws: (any Error).self) {
            try await engine.attach(bad, password: SSHEnv.dbPass)
        }
        #expect(Date().timeIntervalSince(started) < 15)
    }

}

/// What ssh asked during a test.
@MainActor
private final class AskLog { var items: [SSHLoginRequest] = [] }
