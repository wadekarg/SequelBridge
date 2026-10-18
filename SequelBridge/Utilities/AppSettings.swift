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

    private enum Key {
        static let theme = "theme"
        static let editorFontSize = "editorFontSize"
        static let tabWidth = "tabWidth"
        static let autoComplete = "autoComplete"
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