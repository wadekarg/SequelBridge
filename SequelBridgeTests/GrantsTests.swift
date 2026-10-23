//
//  GrantsTests.swift
//  SequelBridgeTests
//
//  What the user let the App Store build reach: folders and files picked in an open panel,
//  kept as security-scoped bookmarks. Outside the sandbox (these tests) a bookmark still
//  records and resolves its item, so the bookkeeping is tested here; the sandbox check
//  (scripts/check-appstore-sandbox.sh) tests the access itself.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Grants: what the user let the sandboxed app reach", .serialized)
struct GrantsTests {
    private func fresh() -> (Grants, URL) {
        let suite = "sb-grants-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("inner"), withIntermediateDirectories: true)
        return (Grants(defaults: defaults), dir)
    }

    @Test("a granted folder covers itself and what it holds, and nothing else")
    func covers() {
        let (grants, dir) = fresh()
        grants.add(dir)
        #expect(grants.covering(dir.path) != nil)
        #expect(grants.covering(dir.appendingPathComponent("inner/x.sqlite").path) != nil)
        #expect(grants.covering(dir.path + "-sibling/x.sqlite") == nil)
        #expect(grants.covering("/private/etc/hosts") == nil)
    }

    @Test("grants are kept for the next launch")
    func kept() {
        let suite = "sb-grants-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Grants(defaults: UserDefaults(suiteName: suite)!).add(dir)
        let later = Grants(defaults: UserDefaults(suiteName: suite)!)
        #expect(later.covering(dir.appendingPathComponent("x").path) != nil)
        #expect(later.grantedPaths == [Grants.canonical(dir.path)])
    }

    @Test("a moved or renamed folder is forgotten, and asked for again, never used for the old path")
    func movedFolder() throws {
        let (grants, dir) = fresh()
        grants.add(dir)
        let moved = URL(fileURLWithPath: dir.path + "-moved")
        try FileManager.default.moveItem(at: dir, to: moved)
        #expect(grants.covering(dir.appendingPathComponent("x").path) == nil)
        #expect(grants.grantedPaths.isEmpty)
    }

    @Test("a deleted folder is forgotten")
    func deletedFolder() throws {
        let (grants, dir) = fresh()
        grants.add(dir)
        try FileManager.default.removeItem(at: dir)
        #expect(grants.covering(dir.path) == nil)
        #expect(grants.grantedPaths.isEmpty)
    }

    @Test("a picked folder that doesn't hold what was needed is kept, and the need still isn't met")
    func otherFolder() {
        let (grants, dir) = fresh()
        let needed = dir.appendingPathComponent("inner/x.sqlite").path
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("sb-grants-other-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(grants.accept(other, for: needed) == nil)
        #expect(grants.accept(dir, for: needed) != nil)
    }

    @Test("a folder reached through a symbolic link is the folder itself, whichever way round it was granted")
    func symlinkedFolder() throws {
        let (grants, dir) = fresh()
        let link = URL(fileURLWithPath: dir.path + "-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        grants.add(link)
        #expect(grants.covering(link.appendingPathComponent("inner/x.sqlite").path) != nil)
        #expect(grants.covering(dir.appendingPathComponent("inner/x.sqlite").path) != nil)
        let (other, otherDir) = fresh()
        let otherLink = URL(fileURLWithPath: otherDir.path + "-link")
        try FileManager.default.createSymbolicLink(at: otherLink, withDestinationURL: otherDir)
        other.add(otherDir)
        #expect(other.covering(otherLink.appendingPathComponent("inner").path) != nil)
    }

    @Test("SSH gets ~/.ssh itself when a folder holding it (the home) is granted, and nothing is asked")
    func sshFolderInGrantedHome() throws {
        let (grants, home) = fresh()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        grants.add(home)
        var asked: [String] = []
        grants.ask = { path, _, _ in asked.append(path); return nil }
        let ssh = grants.sshFolder(home: home.path, own: home.appendingPathComponent("own"))
        #expect(ssh?.path == home.appendingPathComponent(".ssh").path)
        #expect(asked.isEmpty)
    }

    @Test("no ~/.ssh (ssh never ran here): SSH gets a folder of the app's own, made for it, and nothing is asked")
    func noSSHFolder() {
        let (grants, home) = fresh()
        var asked: [String] = []
        grants.ask = { path, _, _ in asked.append(path); return nil }
        let own = home.appendingPathComponent("own")
        #expect(grants.sshFolder(home: home.path, own: own) == own)
        #expect(FileManager.default.fileExists(atPath: own.path))
        #expect(asked.isEmpty)
    }

    @Test("~/.ssh not granted: it is asked for, and the folder picked is used")
    func sshFolderAsked() throws {
        let (grants, home) = fresh()
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        var asked: [String] = []
        grants.ask = { path, _, folder in asked.append(path); return folder ? URL(fileURLWithPath: path) : nil }
        #expect(grants.sshFolder(home: home.path, own: home.appendingPathComponent("own"))?.path == ssh.path)
        #expect(asked == [ssh.path])
    }

    @Test("a path with ~ is looked up in the user's home")
    func tilde() {
        let (grants, _) = fresh()
        let home = URL(fileURLWithPath: Paths.realHome)
        grants.add(home)
        #expect(grants.covering("~/anything").map { $0.path } == home.path)
    }
}
