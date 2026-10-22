//
//  AppSettings.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import Combine
import SwiftUI

enum AppTheme: String, CaseIterable {
    case light  = "Light"
    case dark   = "Dark"
    case system = "System"
}

@MainActor
class AppSettings: ObservableObject {
    // Swift 6.3 InferIsolatedConformances requires an explicit nonisolated publisher.
    // A custom objectWillChange disables @Published/@AppStorage auto-notification, so
    // these settings are backed by UserDefaults directly and fire the publisher on
    // every set. Previously they were @AppStorage, whose changes never reached the
    // custom publisher — theme/font/tab-width silently didn't apply until relaunch.
    nonisolated let objectWillChange = ObservableObjectPublisher()

    private let defaults: UserDefaults

    /// Injectable store so tests don't pollute the real user defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The store the app keeps its settings in: the owner's own, or, for a copy launched
    /// with `-SBSupportDir` (UI tests, the screenshots), a store of its own emptied at each
    /// launch, so a test that changes a setting never changes the owner's. Call once a launch.
    static func store(arguments: [String] = CommandLine.arguments) -> UserDefaults {
        guard arguments.contains("-SBSupportDir"), let apart = UserDefaults(suiteName: isolatedSuite) else { return .standard }
        apart.removePersistentDomain(forName: isolatedSuite)
        return apart
    }

    private static let isolatedSuite = "SequelBridge.launchedApart"

    /// The tab the Settings window shows: Help → Keyboard Shortcuts opens it on Shortcuts.
    /// Not saved: Settings opens on Appearance at each launch.
    var settingsTab: SettingsTab = .appearance {
        willSet { objectWillChange.send() }
    }

    private enum Key {
        static let theme = "theme"
        static let editorFontSize = "editorFontSize"
        static let tabWidth = "tabWidth"
        static let autoComplete = "autoComplete"
        static let contentPageSize = "contentPageSize"
    }

    var theme: AppTheme {
        get { defaults.string(forKey: Key.theme).flatMap(AppTheme.init(rawValue:)) ?? .light }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.theme) }
    }

    var editorFontSize: Double {
        get { defaults.object(forKey: Key.editorFontSize) as? Double ?? 13.0 }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.editorFontSize) }
    }

    var tabWidth: Int {
        get { defaults.object(forKey: Key.tabWidth) as? Int ?? 4 }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.tabWidth) }
    }

    /// Rows per page in the Content tab.
    var contentPageSize: Int {
        get { defaults.object(forKey: Key.contentPageSize) as? Int ?? 200 }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.contentPageSize) }
    }

    var autoComplete: Bool {
        get { defaults.object(forKey: Key.autoComplete) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.autoComplete) }
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }
}