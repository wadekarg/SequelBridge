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
    @State private var editingConnection: Connection?

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
                        Text("\(conn.host):\(conn.port)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editingConnection = conn }
                        .controlSize(.small)
                    Button("Delete") { try? manager.deleteSaved(id: conn.id) }
                        .controlSize(.small)
                        .foregroundColor(.red)
                }
            }
        }
        .sheet(item: $editingConnection) { conn in
            AddConnectionSheet(isPresented: Binding(
                get: { editingConnection != nil },
                set: { if !$0 { editingConnection = nil } }
            ), editingConnection: conn)
        }
    }

    private var shortcutsTab: some View {
        let shortcuts: [(String, String)] = [
            ("⌘↵", "Run query (or selected text)"),
            ("Esc", "Cancel the running query"),
            ("⌃⌥F", "Format the statement"),
            ("⌘T", "New query tab"),
            ("⌘W", "Close current tab"),
            ("⌘,", "Open Settings"),
            ("Click table", "Insert table name at cursor"),
            ("Double-click table", "SELECT * LIMIT 200 in new tab")
        ]
        return List(shortcuts, id: \.0) { shortcut, description in
            HStack {
                Text(shortcut)
                    .font(Theme.mono(13))
                    .frame(width: 140, alignment: .leading)
                Text(description).foregroundColor(.secondary)
            }
        }
    }
}