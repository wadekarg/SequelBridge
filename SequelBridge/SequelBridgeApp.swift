//
//  SequelBridgeApp.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import SwiftUI

@main
struct SequelBridgeApp: App {
    @StateObject private var connectionManager: ConnectionManager
    @StateObject private var appSettings = AppSettings()

    @MainActor
    init() {
        do {
            let cm = try ConnectionManager()
            _connectionManager = StateObject(wrappedValue: cm)
        } catch {
            fatalError("Failed to initialise QueryEngine: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("SequelBridge") {
            HomeView()
                .environmentObject(connectionManager)
                .environmentObject(appSettings)
                .preferredColorScheme(appSettings.colorScheme)
        }
        .defaultSize(width: 960, height: 680)
        .commands {
            CommandGroup(replacing: .help) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appSettings)
                .environmentObject(connectionManager)
        }
    }
}
