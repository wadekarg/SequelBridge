//
//  WorkspaceView.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var manager: ConnectionManager
    @EnvironmentObject private var appSettings: AppSettings
    @StateObject private var session: WorkspaceSession
    init() {
        _session = StateObject(wrappedValue: WorkspaceSession(connections: []))
    }

    var body: some View {
        HSplitView {
            WorkspaceSidebarView(session: session)
                .environmentObject(manager)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)

            WorkspaceMainView(session: session)
                .environmentObject(manager)
                .environmentObject(appSettings)
                .frame(minWidth: 300, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        // Feature buttons in the macOS window toolbar — same position as Sequel Ace
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                HStack(spacing: 1) {
                    ForEach([WorkspaceSession.FeatureTab.structure,
                             .content, .relations, .triggers, .tableInfo], id: \.self) { tab in
                        toolbarButton(tab, disabled: session.selectedTable == nil)
                    }
                    Divider().frame(height: 16).padding(.horizontal, 3)
                    ForEach([WorkspaceSession.FeatureTab.routines, .server, .query, .console], id: \.self) { tab in
                        toolbarButton(tab, disabled: false)
                    }
                }
            }
        }
        .onAppear {
            session.connections = manager.active
            session.activeConnectionAlias = manager.active.first?.alias
            manager.queryEngine.onStatement = { [weak session] sql, rows, error, duration in
                session?.appendConsole(sql: sql, rowsAffected: rows, error: error, duration: duration)
            }
            // Warm only the scanners this workspace will actually use — each is
            // ~90MB, so preloading MySQL's for a Postgres-only workspace is a
            // pointless download.
            let needed = Set(manager.active.map(\.engine.extensionName)).filter { !$0.isEmpty }
            Task {
                for ext in needed {
                    try? await manager.queryEngine.ensureExtensionLoaded(ext)
                }
            }
        }
    }

    // MARK: - Feature toolbar (full-width, above sidebar + content)

    private var featureToolbar: some View {
        HStack(spacing: 2) {
            ForEach([WorkspaceSession.FeatureTab.structure,
                     .content, .relations, .triggers, .tableInfo], id: \.self) { tab in
                toolbarButton(tab, disabled: session.selectedTable == nil)
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            ForEach([WorkspaceSession.FeatureTab.routines, .server, .query, .console], id: \.self) { tab in
                toolbarButton(tab, disabled: false)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func toolbarButton(_ tab: WorkspaceSession.FeatureTab, disabled: Bool) -> some View {
        let isActive = session.activeFeatureTab == tab
        return Button(tab.rawValue) { session.activeFeatureTab = tab }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color(NSColor.textBackgroundColor) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .cornerRadius(4)
            .foregroundColor(disabled ? .secondary.opacity(0.4) : (isActive ? .primary : .secondary))
            .disabled(disabled)
    }
}