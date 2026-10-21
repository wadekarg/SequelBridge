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
import CryptoKit
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

    @Test("ssh asks before trusting a new server when the app can answer; a known-hosts file of its own can stand in")
    func hostKeyChecking() {
        var conn = Connection(name: "t", alias: "t", connectionType: .ssh, host: "db.internal", port: 3306, username: "dbuser")
        conn.sshHost = "bastion.example"
        conn.sshUsername = "me"
        #expect(SSHTunnel.arguments(for: conn, localPort: 13307, keyPath: nil, interactive: true).contains("StrictHostKeyChecking=ask"))
        // With nothing to answer (a script, a test), a new server is trusted as before.
        #expect(SSHTunnel.arguments(for: conn, localPort: 13307, keyPath: nil, interactive: false).contains("StrictHostKeyChecking=accept-new"))
        SSHTunnel.knownHostsFile = "/tmp/sb_known_hosts"
        defer { SSHTunnel.knownHostsFile = nil }
        #expect(SSHTunnel.arguments(for: conn, localPort: 13307, keyPath: nil).contains("UserKnownHostsFile=/tmp/sb_known_hosts"))
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

    /// Runs `body` with `answer` answering ssh's questions; returns what ssh asked. A new
    /// server's key is trusted unasked unless `hostKeys`, as on a Mac that met it before.
    func answering(hostKeys: Bool = false, _ answer: @escaping (SSHLoginRequest) -> String?,
                   _ body: () async throws -> Void) async throws -> [SSHLoginRequest] {
        let asked = AskLog()
        SSHTunnel.prompter = { @MainActor request in
            if request.kind == .hostKey, !hostKeys { return "yes" }
            asked.items.append(request); return answer(request)
        }
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

    /// otpuser logs in with a one-time code alone (google-authenticator's PAM module on the
    /// old-style server). The app's answer is what an authenticator app would show now.
    @Test("a one-time code: ssh asks for the code an authenticator app shows, and the app answers",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func oneTimeCodeLogin() async throws {
        var c = sshConnection(alias: "sshotp", sshPort: SSHEnv.legacyPort)
        c.sshUsername = "otpuser"
        let secret = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x21, 0xDE, 0xAD, 0xBE, 0xEF])   // base32 JBSWY3DPEHPK3PXP
        let asked = try await answering({ $0.kind == .code ? Self.totp(secret: secret) : nil }) {
            try await attachAndQuery(c)
        }
        #expect(asked.map(\.kind) == [.code], "asked: \(asked.map(\.prompt))")
        #expect(asked.first?.prompt.contains("Verification code") == true, "asked: \(asked.map(\.prompt))")
    }

    @Test("the test's authenticator agrees with RFC 6238's own example")
    func totpReference() {
        #expect(Self.totp(secret: Data("12345678901234567890".utf8), at: Date(timeIntervalSince1970: 59)) == "287082")
    }

    /// A TOTP code (RFC 6238: HMAC-SHA1, 30-second steps, 6 digits), as an authenticator app shows it.
    static func totp(secret: Data, at date: Date = Date()) -> String {
        let counter = withUnsafeBytes(of: UInt64(date.timeIntervalSince1970 / 30).bigEndian) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: counter, using: SymmetricKey(data: secret)))
        let o = Int(mac[19] & 0x0F)
        let value = (UInt32(mac[o] & 0x7F) << 24 | UInt32(mac[o + 1]) << 16 | UInt32(mac[o + 2]) << 8 | UInt32(mac[o + 3])) % 1_000_000
        return String(format: "%06u", value)
    }

    /// A key loaded in ssh-agent and no key file on the connection: ssh offers the agent's
    /// keys, as it does at a terminal. The agent is a private one, so the user's own
    /// agent is never asked.
    @Test("a key in ssh-agent logs in, with no key file set on the connection",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func agentLogin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-agent-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let socket = dir.appendingPathComponent("agent.sock").path
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket]
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        defer { agent.terminate() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket) { try await Task.sleep(nanoseconds: 100_000_000) }
        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        add.arguments = [SSHEnv.keyPath]
        add.environment = ["SSH_AUTH_SOCK": socket]
        add.standardError = FileHandle.nullDevice
        try add.run()
        add.waitUntilExit()
        #expect(add.terminationStatus == 0, "ssh-add couldn't load the test key")

        let before = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        setenv("SSH_AUTH_SOCK", socket, 1)
        defer { if let before { setenv("SSH_AUTH_SOCK", before, 1) } else { unsetenv("SSH_AUTH_SOCK") } }
        var c = sshConnection(alias: "sshagent")
        c.sshKeyPath = ""
        try await attachAndQuery(c)
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

    // MARK: - Server keys (needs SB_SSH_VERIFY=1), each on a known-hosts file of its own

    /// Runs `body` with a throwaway known_hosts holding `contents`, never the user's own.
    func withKnownHosts(_ contents: String, _ body: (String) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-kh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("known_hosts").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        SSHTunnel.knownHostsFile = path
        defer { SSHTunnel.knownHostsFile = nil; SSHTunnel.trusted = [:] }
        try await body(path)
    }

    func file(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    @Test("a server never met before asks to be trusted, with its key's fingerprint; trusted, it's remembered",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func newServerTrusted() async throws {
        try await withKnownHosts("") { path in
            let asked = try await answering(hostKeys: true, { $0.kind == .hostKey ? "yes" : nil }) {
                try await attachAndQuery(sshConnection(alias: "sshnew"))
            }
            #expect(asked.map(\.kind) == [.hostKey], "asked: \(asked.map(\.prompt))")
            #expect(asked.first.flatMap { SSHHostKey(newServerPrompt: $0.prompt) }?.fingerprint.hasPrefix("SHA256:") == true)
            #expect(file(path).contains("[127.0.0.1]:\(SSHEnv.port)"), "not remembered: \(file(path))")
        }
    }

    @Test("a server not trusted stops the connection at once, saying why; nothing is remembered",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func newServerDeclined() async throws {
        try await withKnownHosts("") { path in
            let engine = try QueryEngine()
            var reason = ""
            let started = Date()
            _ = try await answering(hostKeys: true, { _ in nil }) {
                do { try await engine.attach(sshConnection(alias: "sshno"), password: SSHEnv.dbPass) }
                catch { reason = QueryEngine.extractReason(from: error) }
            }
            #expect(reason.contains("trust"), "\(reason)")
            #expect(Date().timeIntervalSince(started) < 10)
            #expect(file(path).isEmpty, "remembered: \(file(path))")
        }
    }

    @Test("a changed key stops the login and says so; with the old key forgotten, the confirmed new one connects unasked",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func changedKey() async throws {
        let fake = try fakeHostKey()
        try await withKnownHosts("[127.0.0.1]:\(SSHEnv.port) \(fake)\n") { path in
            var change: SSHHostKeyChange?
            do { try await QueryEngine().attach(sshConnection(alias: "sshchg"), password: SSHEnv.dbPass) }
            catch let c as SSHHostKeyChange { change = c }
            let c = try #require(change, "the login didn't stop at the changed key")
            #expect(c.key.host == "[127.0.0.1]:\(SSHEnv.port)" && c.knownHostsFile == path && c.line == 1)

            try SSHTunnel.forget(c)
            let asked = try await answering(hostKeys: true, { _ in nil }) {
                try await attachAndQuery(sshConnection(alias: "sshchg2"))
            }
            #expect(asked.isEmpty, "asked again: \(asked.map(\.prompt))")
            #expect(file(path).contains("[127.0.0.1]:\(SSHEnv.port)") && !file(path).contains(fake), "\(file(path))")
        }
    }

    @Test("Test Connection keeps a changed key for \"Forget the Old Key…\" and Connect throws it; forgotten, both go through",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func changedKeyInTheApp() async throws {
        let fake = try fakeHostKey()
        // A fixture list: Connect finds the password there, not in the Keychain.
        let conn = sshConnection(alias: "sshmgr")
        var entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(conn)) as! [String: Any]
        entry["password"] = SSHEnv.dbPass
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("sb-mgr-\(UUID().uuidString.prefix(8)).json")
        try JSONSerialization.data(withJSONObject: [entry]).write(to: list)
        let manager = try ConnectionManager(arguments: ["app", "-SBConnectionsFile", list.path])

        try await withKnownHosts("[127.0.0.1]:\(SSHEnv.port) \(fake)\n") { _ in
            let message = await manager.testConnection(conn, password: SSHEnv.dbPass)
            #expect(message?.contains("key has changed") == true, "\(message ?? "connected")")
            #expect(manager.hostKeyChange?.key.host == "[127.0.0.1]:\(SSHEnv.port)", "Test Connection didn't keep it")
        }
        try await withKnownHosts("[127.0.0.1]:\(SSHEnv.port) \(fake)\n") { _ in
            var thrown: SSHHostKeyChange?
            do { try await manager.connect([conn]) } catch let c as SSHHostKeyChange { thrown = c }
            let change = try #require(thrown, "Connect didn't stop at the changed key")
            try manager.forgetHostKey(change)
            #expect(manager.hostKeyChange == nil)
            try await manager.connect([conn])
            #expect(manager.active.map(\.alias) == ["sshmgr"])
            manager.disconnect("sshmgr")
        }
    }

    /// Picking another database on a MySQL connection re-attaches it. Over SSH that stopped
    /// the tunnel and logged in again: a password, or a one-time code, asked at every pick.
    @Test("switching a MySQL connection's database over SSH keeps its tunnel: ssh asks once, not at every pick",
          .enabled(if: SSHEnv.enabled && !SSHEnv.keyPath.isEmpty))
    func databaseSwitchKeepsTheTunnel() async throws {
        let conn = passwordConnection(alias: "sshswitch")
        var entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(conn)) as! [String: Any]
        entry["password"] = SSHEnv.dbPass
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("sb-switch-\(UUID().uuidString.prefix(8)).json")
        try JSONSerialization.data(withJSONObject: [entry]).write(to: list)
        let manager = try ConnectionManager(arguments: ["app", "-SBConnectionsFile", list.path])
        let asked = try await answering({ $0.kind == .password ? "sbssh123" : nil }) {
            try await manager.connect([conn])
            _ = try await manager.switchDatabase(alias: "sshswitch", to: "sbwrite")
            _ = try await manager.switchDatabase(alias: "sshswitch", to: "sbtest")
            let r = try await manager.queryEngine.query(#"SELECT COUNT(*) FROM "sshswitch"."sbtest"."customers""#)
            #expect(r.rows.first?.first == "3")
        }
        #expect(asked.count == 1, "ssh logged in \(asked.count) times: \(asked.map(\.prompt))")
        try? await manager.queryEngine.detach("sshswitch")
    }

    /// A public key of the test server's own type (ED25519) that isn't the server's.
    func fakeHostKey() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-fake-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent("fake").path]
        try keygen.run(); keygen.waitUntilExit()
        return file(dir.appendingPathComponent("fake.pub").path).split(separator: " ").prefix(2).joined(separator: " ")
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
