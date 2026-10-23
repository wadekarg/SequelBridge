//
//  PathsTests.swift
//  SequelBridgeTests
//
//  In the App Store build the sandbox gives the app a home of its own (its container), and
//  NSString's expandingTildeInPath expands "~" to it. A key or a SQLite file the user typed
//  as "~/…" is in their own home: Paths says where that is, from the user database.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("A path with ~ is in the user's home")
struct PathsTests {
    @Test("~ and ~/… are the user's home; other paths are as typed")
    func expanding() {
        let home = Paths.realHome
        #expect(Paths.expandingTilde("~") == home)
        #expect(Paths.expandingTilde("~/.ssh/id_ed25519") == home + "/.ssh/id_ed25519")
        #expect(Paths.expandingTilde("/var/db/x.sqlite") == "/var/db/x.sqlite")
        #expect(Paths.expandingTilde("data/x.sqlite") == "data/x.sqlite")
    }

    @Test("the home comes from the user database, not from $HOME (which the sandbox points at the container)")
    func notFromHOME() {
        let saved = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", "/private/tmp/sb-not-home", 1)
        defer { if let saved { setenv("HOME", saved, 1) } else { unsetenv("HOME") } }
        #expect(Paths.userHome() == NSHomeDirectoryForUser(NSUserName()))
        #expect(Paths.userHome() != "/private/tmp/sb-not-home")
    }

    @Test("a typed ~/ key path and SQLite file mean the user's home")
    func typedPaths() {
        var ssh = Connection(name: "s", alias: "s", connectionType: .ssh)
        ssh.sshKeyPath = "~/.ssh/id_rsa"
        #expect(SSHTunnel.keyPath(ssh) == Paths.realHome + "/.ssh/id_rsa")
        var lite = Connection(name: "l", alias: "l")
        lite.engine = .sqlite
        lite.database = "~/data/app.sqlite"
        #expect(QueryEngine.sqliteFile(lite) == Paths.realHome + "/data/app.sqlite")
    }
}
