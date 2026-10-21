//
//  SettingsView.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var manager: ConnectionManager
    @EnvironmentObject private var updater: AppUpdater
    @State private var editingConnection: Connection?
    /// The favorite Delete asks about.
    @State private var removing: Connection?

    var body: some View {
        TabView {
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            editorTab
                .tabItem { Label("Editor", systemImage: "text.cursor") }
            connectionsTab
                .tabItem { Label("Connections", systemImage: "server.rack") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            updatesTab
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 480, height: 340)
    }

    private var appearanceTab: some View {
        Form {
            Picker("Theme", selection: $appSettings.theme) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.rawValue).tag(theme)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
        .padding()
    }

    /// New versions (AppUpdater): checked for once a day when allowed, or now.
    private var updatesTab: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return Form {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }))
                .disabled(!updater.isRunning)
                .accessibilityIdentifier("settings.updates.auto")
            HStack {
                Text("SequelBridge \(version) (\(build))")
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            Text("New versions come from the project's GitHub releases, signed with its key; an update "
                 + "signed otherwise is refused. A check sends nothing about you or your databases.")
                .font(.caption).foregroundColor(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var editorTab: some View {
        Form {
            Slider(value: $appSettings.editorFontSize, in: 10...20, step: 1) {
                Text("Font Size: \(Int(appSettings.editorFontSize))pt")
            }
            Stepper("Tab Width: \(appSettings.tabWidth)", value: $appSettings.tabWidth, in: 2...8)
            Toggle("Auto-complete", isOn: $appSettings.autoComplete)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var connectionsTab: some View {
        List {
            ForEach(manager.saved) { conn in
                HStack {
                    Circle().fill(conn.displayColor).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conn.name).font(.body)
                        Text(conn.displayHost).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editingConnection = conn }
                        .controlSize(.small)
                    Button("Delete") { removing = conn }
                        .controlSize(.small)
                        .foregroundColor(.red)
                }
            }
        }
        .confirmationDialog("Delete this favorite?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { conn in
            Button("Delete “\(conn.name)”", role: .destructive) { try? manager.deleteSaved(id: conn.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its saved password is removed from the Keychain too.")
        }
        .sheet(item: $editingConnection) { conn in
            AddConnectionSheet(isPresented: Binding(
                get: { editingConnection != nil },
                set: { if !$0 { editingConnection = nil } }
            ), editingConnection: conn)
        }
    }

    private var shortcutsTab: some View {
        List(Shortcuts.all, id: \.keys) { shortcut in
            HStack(alignment: .firstTextBaseline) {
                Text(shortcut.keys)
                    .font(Theme.mono(13))
                    .frame(width: 160, alignment: .leading)
                Text(shortcut.action).foregroundColor(.secondary)
            }
        }
    }
}