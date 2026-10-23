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
    @StateObject private var appSettings = AppSettings(defaults: AppSettings.store())
    @StateObject private var updater = AppUpdater()
    #if APP_STORE
    @NSApplicationDelegateAdaptor(AppStoreDelegate.self) private var appStoreDelegate
    #endif

    @MainActor
    init() {
        do {
            let cm = try ConnectionManager()
            _connectionManager = StateObject(wrappedValue: cm)
        } catch {
            fatalError("Failed to initialise QueryEngine: \(error)")
        }
        // What ssh asks while it logs in (a password, a key's passphrase, a one-time code)
        // is asked in a dialog. Tests set their own answerer.
        SSHTunnel.prompter = { await SSHLoginPrompt.answer($0) }
        SSHTunnel.knownHostsFile = SSHTunnel.knownHostsFile(from: CommandLine.arguments)
        #if APP_STORE
        // The sandbox: SSH reads the ~/.ssh and key files the user granted.
        SSHTunnel.sshFolderGrant = { Grants.shared.sshFolder() }
        SSHTunnel.keyGrant = { Grants.shared.file($0) != nil }
        // A SQLite file's folder (SQLite writes its journal beside the file).
        QueryEngine.fileGrant = { Grants.shared.folder(holding: $0) }
        #endif
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
            #if !APP_STORE
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            #endif
            CommandGroup(replacing: .help) { HelpMenu(appSettings: appSettings) }
        }

        // Opened from Help → Acknowledgements, so not listed in the Window menu as well.
        Window("Acknowledgements", id: AcknowledgementsView.windowID) {
            AcknowledgementsView()
                .frame(minWidth: 480, minHeight: 320)
                .preferredColorScheme(appSettings.colorScheme)
        }
        .defaultSize(width: 680, height: 600)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environmentObject(appSettings)
                .environmentObject(connectionManager)
                .environmentObject(updater)
        }
    }
}

#if APP_STORE
/// The App Store build: items opened with the app (the sandbox check's folders) and the check.
final class AppStoreDelegate: NSObject, NSApplicationDelegate {
    private var opened: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) { opened += urls }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.contains("-SBSandboxCheck") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            Task { @MainActor in await SandboxCheck.run(arguments: CommandLine.arguments, opened: self.opened) }
        }
    }
}
#endif
