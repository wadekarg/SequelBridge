//
//  ConnectionListView.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import SwiftUI

struct ConnectionListView: View {
    @EnvironmentObject private var manager: ConnectionManager
    @Binding var selectedIds: Set<UUID>
    @Binding var showAddSheet: Bool
    @State private var editingConnection: Connection?

    var body: some View {
        List {
            ForEach(manager.saved) { conn in
                ConnectionRowView(
                    connection: conn,
                    isSelected: selectedIds.contains(conn.id),
                    onToggle: { toggle(conn.id) }
                )
                .contextMenu {
                    Button("Edit") { editingConnection = conn }
                    Divider()
                    Button("Delete", role: .destructive) {
                        try? manager.deleteSaved(id: conn.id)
                        selectedIds.remove(conn.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .sheet(item: $editingConnection) { conn in
            AddConnectionSheet(isPresented: Binding(
                get: { editingConnection != nil },
                set: { if !$0 { editingConnection = nil } }
            ), editingConnection: conn)
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIds.contains(id) { selectedIds.remove(id) }
        else { selectedIds.insert(id) }
    }
}