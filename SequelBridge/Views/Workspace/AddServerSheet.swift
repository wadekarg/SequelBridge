//  AddServerSheet.swift — Pick an existing favourite to add to the workspace

import SwiftUI

struct AddServerSheet: View {
    @EnvironmentObject private var manager: ConnectionManager
    @Binding var isPresented: Bool
    @Binding var showNewConnection: Bool
    let alreadyConnected: [UUID]
    let onConnect: (Connection) -> Void

    var available: [Connection] {
        manager.saved.filter { !alreadyConnected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Add Server to Workspace")
                    .font(.title2).bold()
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary).font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            if available.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("All your saved connections are already open")
                        .foregroundColor(.secondary)
                    Text("or add a new one below")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(available) { conn in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(conn.displayColor)
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conn.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text(conn.displayHost)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(conn.connectionType.rawValue)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                            Button("Connect") {
                                onConnect(conn)
                                isPresented = false
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        showNewConnection = true
                    }
                } label: {
                    Label("New Connection…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 420, height: available.isEmpty ? 280 : min(CGFloat(available.count) * 68 + 140, 480))
    }
}
