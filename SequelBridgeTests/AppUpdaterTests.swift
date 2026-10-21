//
//  AppUpdaterTests.swift
//  SequelBridgeTests
//
//  The updater (Sparkle): where it looks for new versions, the key their signatures are
//  checked with, and the copies it stays out of — a test run, the screenshots' copy, a
//  Debug build — which would otherwise ask whether to check automatically and fetch the
//  feed.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("Updates: when the updater runs, and where it looks")
struct AppUpdaterTests {
    @Test("a test run, a copy launched with its own files, or a Debug build starts no updater; -SBUpdateFeed starts one")
    func whenItRuns() {
        #expect(AppUpdater.startsUpdater(arguments: ["app"], environment: [:], debugBuild: false))
        #expect(!AppUpdater.startsUpdater(arguments: ["app", "-SBSupportDir", "/tmp/x"], environment: [:], debugBuild: false))
        #expect(!AppUpdater.startsUpdater(arguments: ["app", "-SBConnectionsFile", "/tmp/c.json"], environment: [:], debugBuild: false))
        #expect(!AppUpdater.startsUpdater(arguments: ["app"], environment: ["XCTestConfigurationFilePath": "/tmp/t"], debugBuild: false))
        #expect(!AppUpdater.startsUpdater(arguments: ["app"], environment: [:], debugBuild: true))
        // The updater's own end-to-end check names a local feed.
        #expect(AppUpdater.startsUpdater(arguments: ["app", "-SBUpdateFeed", "http://127.0.0.1:8765/appcast.xml"],
                                         environment: [:], debugBuild: true))
    }

    @Test("the feed is Info.plist's, unless -SBUpdateFeed names another")
    func feed() {
        #expect(AppUpdater.feedOverride(["app"]) == nil)
        #expect(AppUpdater.feedOverride(["app", "-SBUpdateFeed"]) == nil)
        #expect(AppUpdater.feedOverride(["app", "-SBUpdateFeed", "http://127.0.0.1:8765/appcast.xml"]) == "http://127.0.0.1:8765/appcast.xml")
    }

    /// The app is this test run's host: its Info.plist is the one that ships.
    @Test("Info.plist names the feed on GitHub Releases and the key updates are signed with")
    func infoPlist() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://github.com/wadekarg/SequelBridge/releases/latest/download/appcast.xml")
        let key = info["SUPublicEDKey"] as? String ?? ""
        #expect(Data(base64Encoded: key)?.count == 32, "SUPublicEDKey is not an Ed25519 public key: \(key)")
    }
}
