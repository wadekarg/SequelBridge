//
//  KeychainTests.swift
//  SequelBridgeTests
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Keychain Tests")
struct KeychainTests {
    // Each test uses its own UUID to avoid cross-test interference
    @Test func saveAndLoad() {
        let id = UUID()
        defer { Keychain.delete(for: id) }
        Keychain.save("secret123", for: id)
        #expect(Keychain.load(for: id) == "secret123")
    }

    @Test func loadMissingReturnsNil() {
        #expect(Keychain.load(for: UUID()) == nil)
    }

    @Test func delete() {
        let id = UUID()
        Keychain.save("secret", for: id)
        Keychain.delete(for: id)
        #expect(Keychain.load(for: id) == nil)
    }

    @Test func overwrite() {
        let id = UUID()
        defer { Keychain.delete(for: id) }
        Keychain.save("first", for: id)
        Keychain.save("second", for: id)
        #expect(Keychain.load(for: id) == "second")
    }
}