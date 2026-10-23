//
//  DistributionTests.swift
//  SequelBridgeTests
//
//  Two builds of one app: the DMG/Homebrew one, as before, and the App Store one, in the
//  App Sandbox, which refuses Unix sockets and ssh-agent's socket and lets the app reach only
//  what the user granted.
//

import Testing
@testable import SequelBridge

@Suite("Two builds: the DMG one and the App Store one")
struct DistributionTests {
    @Test("the unit tests run in the DMG build")
    func current() {
        #expect(Distribution.current == .direct)
    }

    @Test("the App Store build offers no sockets or ssh-agent and needs grants; the DMG build is as before")
    func differences() {
        #expect(Distribution.direct.offersSockets && Distribution.direct.offersSSHAgent && !Distribution.direct.needsGrants)
        #expect(!Distribution.appStore.offersSockets && !Distribution.appStore.offersSSHAgent && Distribution.appStore.needsGrants)
    }
}
