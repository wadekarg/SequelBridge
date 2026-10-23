//
//  SSHSandboxTests.swift
//  SequelBridgeTests
//
//  SSH in the App Store build: ssh may read only what the user granted. Its ~/.ssh is the
//  granted folder (config, keys, known_hosts), ssh-agent's socket is out of reach, and a key
//  kept elsewhere is granted on its own. The DMG build sets none of this.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("SSH in the App Store build", .serialized)
struct SSHSandboxTests {
    private func conn() -> Connection {
        var c = Connection(name: "t", alias: "t", connectionType: .ssh, host: "127.0.0.1", port: 3306, username: "u")
        c.sshHost = "127.0.0.1"; c.sshPort = 1; c.sshUsername = "me"
        return c
    }

    private func folder(config: String?) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ssh-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let config { try! config.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8) }
        return dir
    }

    @Test("ssh reads the granted folder's config and known_hosts, and never asks ssh-agent")
    func arguments() {
        let dir = folder(config: "Host *\n  ServerAliveCountMax 3\n")
        let args = SSHTunnel.arguments(for: conn(), localPort: 13307, keyPath: nil, sshFolder: dir.path)
        let joined = args.joined(separator: " ")
        #expect(joined.contains("-F \(dir.path)/config"), "\(args)")
        #expect(args.contains("IdentityAgent=none"))
        #expect(args.contains("UserKnownHostsFile=\(dir.path)/known_hosts"))
        let bare = SSHTunnel.arguments(for: conn(), localPort: 13307, keyPath: nil, sshFolder: folder(config: nil).path)
        #expect(bare.joined(separator: " ").contains("-F /dev/null"), "\(bare)")
        let dmg = SSHTunnel.arguments(for: conn(), localPort: 13307, keyPath: nil)
        #expect(!dmg.contains("IdentityAgent=none") && !dmg.contains("-F"), "\(dmg)")
    }

    @Test("a test's own known_hosts still wins")
    func knownHostsOverride() {
        let saved = SSHTunnel.knownHostsFile
        SSHTunnel.knownHostsFile = "/private/tmp/sb-test-known_hosts"
        defer { SSHTunnel.knownHostsFile = saved }
        let args = SSHTunnel.arguments(for: conn(), localPort: 13307, keyPath: nil, sshFolder: folder(config: nil).path)
        #expect(args.filter { $0.hasPrefix("UserKnownHostsFile=") } == ["UserKnownHostsFile=/private/tmp/sb-test-known_hosts"])
    }

    @Test("no ~/.ssh granted: the connection says so before ssh runs")
    func folderMissing() async {
        SSHTunnel.sshFolderGrant = { nil }
        defer { SSHTunnel.sshFolderGrant = nil }
        do {
            try await SSHTunnel().start(conn: conn())
            Issue.record("started")
        } catch {
            #expect(error.localizedDescription == SSHTunnel.sshFolderMissing, "\(error)")
        }
    }

    @Test("a key ssh can't read: the connection says which, before ssh runs")
    func keyMissing() async throws {
        let dir = folder(config: nil)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("sb-elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let key = elsewhere.appendingPathComponent("id_ed25519").path
        FileManager.default.createFile(atPath: key, contents: Data("key".utf8))
        SSHTunnel.sshFolderGrant = { dir }
        SSHTunnel.keyGrant = { _ in false }
        defer { SSHTunnel.sshFolderGrant = nil; SSHTunnel.keyGrant = nil }
        var c = conn()
        c.sshKeyPath = key
        do {
            try await SSHTunnel().start(conn: c)
            Issue.record("started")
        } catch {
            #expect(error.localizedDescription.contains("can't read the SSH key at \(key)"), "\(error)")
        }
    }

    @Test("a key that isn't there (moved, renamed) says so, and isn't asked for")
    func keyNotThere() async {
        let dir = folder(config: nil)
        var asked: [String] = []
        SSHTunnel.sshFolderGrant = { dir }
        SSHTunnel.keyGrant = { asked.append($0); return false }
        defer { SSHTunnel.sshFolderGrant = nil; SSHTunnel.keyGrant = nil }
        var c = conn()
        c.sshKeyPath = "/private/tmp/sb-gone-\(UUID().uuidString)/id_ed25519"
        do {
            try await SSHTunnel().start(conn: c)
            Issue.record("started")
        } catch {
            #expect(error.localizedDescription == "SSH key not found at \(c.sshKeyPath)", "\(error)")
        }
        #expect(asked.isEmpty)
    }

    @Test("a config ssh can't use: its own reason reaches the user")
    func badConfig() async {
        let dir = folder(config: "NoSuchOption yes\n")
        SSHTunnel.sshFolderGrant = { dir }
        defer { SSHTunnel.sshFolderGrant = nil }
        do {
            try await SSHTunnel().start(conn: conn())
            Issue.record("started")
        } catch {
            #expect(error.localizedDescription.contains("Bad configuration option"), "\(error)")
        }
    }
}
