//
//  TableDetailView.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import SwiftUI

struct TableDetailView: View {
    let table: TableInfo
    let connection: Connection
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: table.type == .view ? "eye" : "tablecells")
                    .foregroundColor(connection.displayColor)
                Text(table.name).font(.headline)
                Spacer()
                Button("SELECT *") {
                    session.addTab()
                    if let idx = session.tabs.firstIndex(where: { $0.id == session.activeTabId }) {
                        session.tabs[idx].sql =
                            "SELECT *\nFROM \"\(connection.alias)\".\"\(table.name)\"\nLIMIT 200"
                        session.tabs[idx].title = table.name
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)

            Divider()

            if table.columns.isEmpty {
                Text("Expand table in sidebar to load columns")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding()
            } else {
                List(table.columns) { col in
                    HStack(spacing: 8) {
                        if col.isPrimaryKey {
                            Image(systemName: "key.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        } else {
                            Image(systemName: col.nullable ? "circle.dotted" : "circle.fill")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text(col.name).font(.system(size: 12))
                        Spacer()
                        Text(col.dataType)
                            .font(Theme.mono(11))
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}