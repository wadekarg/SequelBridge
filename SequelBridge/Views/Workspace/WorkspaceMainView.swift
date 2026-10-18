//  WorkspaceMainView.swift

import SwiftUI

struct WorkspaceMainView: View {
    @EnvironmentObject private var manager: ConnectionManager
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        currentPanel
    }

    // MARK: - Panel routing

    @ViewBuilder
    private var currentPanel: some View {
        let conn = session.connections.first(where: { $0.alias == session.activeConnectionAlias })
                ?? session.connections.first
        let table = session.selectedTable

        switch session.activeFeatureTab {
        case .structure:
            if let table, let conn {
                StructurePanel(table: table, conn: conn, session: session)
                    .environmentObject(manager)
            } else { noTableSelected }
        case .content:
            if let table, let conn {
                ContentPanel(table: table, conn: conn, session: session)
                    .environmentObject(manager)
            } else { noTableSelected }
        case .relations:
            if let table, let conn {
                RelationsPanel(table: table, conn: conn, session: session)
                    .environmentObject(manager)
            } else { noTableSelected }
        case .triggers:
            if let table, let conn {
                TriggersPanel(table: table, conn: conn, session: session)
                    .environmentObject(manager)
            } else { noTableSelected }
        case .tableInfo:
            if let table, let conn {
                TableInfoPanel(table: table, conn: conn, session: session)
                    .environmentObject(manager)
            } else { noTableSelected }
        case .routines:
            if let conn {
                RoutinesPanel(conn: conn, session: session)
                    .environmentObject(manager)
            } else { noTableSelected }
        case .server:
            if let conn {
                ServerPanel(conn: conn, session: session)
                    .environmentObject(manager)
            } else { noTableSelected }
        case .query:
            QueryPanelView(session: session)
                .environmentObject(manager)
                .environmentObject(appSettings)
        case .console:
            ConsolePanelView(session: session)
        }
    }

    private var noTableSelected: some View {
        VStack(spacing: 12) {
            Image(systemName: "tablecells").font(.system(size: 40)).foregroundColor(.secondary.opacity(0.3))
            Text("Select a table in the sidebar").foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
