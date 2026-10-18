//
//  AppSettingsTests.swift
//  SequelBridgeTests
//
//  AppSettings declares a custom objectWillChange, which disables @AppStorage's
//  automatic notifications — theme/font/tab width silently didn't apply until
//  relaunch. Settings are now UserDefaults-backed and fire the publisher on set.
//

import Combine
import Foundation
import SwiftUI
import Testing
@testable import SequelBridge

@MainActor
@Suite("AppSettings observability & persistence")
struct AppSettingsTests {

    private func tempDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sb.test.\(UUID().uuidString)")!
    }

    @Test("changing a setting notifies observers so it applies without relaunch")
    func changesNotify() {
        let s = AppSettings(defaults: tempDefaults())
        var count = 0
        let c = s.objectWillChange.sink { count += 1 }
        defer { c.cancel() }
        s.theme = .dark
        s.editorFontSize = 16
        s.tabWidth = 2
        s.autoComplete = false
        #expect(count >= 4)
    }

    @Test("settings persist to and reload from the store")
    func persists() {
        let store = tempDefaults()
        let s = AppSettings(defaults: store)
        s.theme = .dark
        s.tabWidth = 8
        s.editorFontSize = 18
        s.autoComplete = false
        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.theme == .dark)
        #expect(reloaded.tabWidth == 8)
        #expect(reloaded.editorFontSize == 18)
        #expect(reloaded.autoComplete == false)
    }

    @Test("unset settings fall back to sensible defaults")
    func defaultsWhenUnset() {
        let s = AppSettings(defaults: tempDefaults())
        #expect(s.theme == .light)
        #expect(s.editorFontSize == 13.0)
        #expect(s.tabWidth == 4)
        #expect(s.autoComplete == true)
        #expect(s.colorScheme == .light)
    }
}
