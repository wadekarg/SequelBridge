//
//  HomeView.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import SwiftUI
import AppKit

struct HomeView: View {
    @EnvironmentObject private var manager: ConnectionManager
    @State private var selectedIds: Set<UUID> = []
    @State private var editingConnection: Connection?   // non-nil → edit sheet
    /// The favorite Remove from Favorites asks about.
    @State private var removing: Connection?
    @State private var showNewConnectionSheet = false   // "New Connection" sheet
    @State private var showWorkspace = false
    @State private var connectError: String?
    @State private var keyChange: SSHHostKeyChange?      // the changed SSH key connectError is about
    @State private var isConnecting = false

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                // Left panel — favorites list
                VStack(spacing: 0) {
                    header
                    Divider()
                    if manager.saved.isEmpty { emptyState } else { connectionList }
                    Divider()
                    footer
                }
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

                Divider()

                // Right panel — empty by default, shows hint
                rightPanel
            }
            .navigationDestination(isPresented: $showWorkspace) {
                WorkspaceView()
                    .environmentObject(manager)
            }
        }
        // Removing a favorite deletes its saved password too: only after a yes.
        .confirmationDialog("Remove this favorite?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { conn in
            Button("Remove “\(conn.name)”", role: .destructive) {
                try? manager.deleteSaved(id: conn.id)
                selectedIds.remove(conn.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its saved password is removed from the Keychain too.")
        }
        // Edit sheet — .sheet(item:) guarantees a fresh view instance per connection,
        // so the pre-filled init always runs with the correct data.
        .sheet(item: $editingConnection, onDismiss: { manager.reloadSaved() }) { conn in
            AddConnectionSheet(
                isPresented: Binding(
                    get: { true },
                    set: { if !$0 { editingConnection = nil } }
                ),
                editingConnection: conn,
                onConnect: {
                    selectedIds = [conn.id]
                    Task { await connect() }
                }
            )
        }
        // New connection sheet
        .sheet(isPresented: $showNewConnectionSheet, onDismiss: { manager.reloadSaved() }) {
            AddConnectionSheet(isPresented: $showNewConnectionSheet)
        }
        .frame(minWidth: 800, minHeight: 520)
        .onAppear { fitWindowToScreen() }
    }

    // MARK: - Subviews

    private var rightPanel: some View {
        VStack(spacing: 16) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .grayscale(1.0)
                .opacity(0.35)
            Text("SequelBridge")
                .font(.title2).bold()
                .foregroundColor(.secondary.opacity(0.5))
            VStack(spacing: 6) {
                Text("Click a connection on the left to edit or connect")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("or use the Connect button at the bottom to open a workspace")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SequelBridge")
                    .font(.title2).bold()
                Text("Select one or more connections to open")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button {
                showNewConnectionSheet = true
            } label: {
                Label("New Connection", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private struct ConnGroup: Identifiable { let id: String; let folder: String; let conns: [Connection] }

    /// Connections grouped by their `folder`: ungrouped first (no header), then
    /// named folders alphabetically. Order within a group follows the saved list.
    private var groupedConnections: [ConnGroup] {
        let grouped = Dictionary(grouping: manager.saved) { $0.folder }
        var out: [ConnGroup] = []
        if let ungrouped = grouped[""], !ungrouped.isEmpty {
            out.append(ConnGroup(id: "", folder: "", conns: ungrouped))
        }
        for folder in grouped.keys.filter({ !$0.isEmpty })
            .sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            out.append(ConnGroup(id: folder, folder: folder, conns: grouped[folder] ?? []))
        }
        return out
    }

    private var connectionList: some View {
        List {
            ForEach(groupedConnections) { group in
                if group.folder.isEmpty {
                    ForEach(group.conns) { conn in
                        connectionRow(conn)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    }
                } else {
                    Section {
                        ForEach(group.conns) { conn in
                            connectionRow(conn)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                        }
                    } header: {
                        Text(group.folder)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func connectionRow(_ conn: Connection) -> some View {
        HStack(spacing: Theme.space3) {
            // Checkbox
            Button { toggle(conn.id) } label: {
                Image(systemName: selectedIds.contains(conn.id) ? "checkmark.square.fill" : "square")
                    .foregroundColor(selectedIds.contains(conn.id) ? conn.displayColor : .secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.select.\(conn.alias)")

            // The connection's color as an edge, not a dot: it reads at any size and
            // matches the tab underline the same server gets inside the workspace.
            RoundedRectangle(cornerRadius: Theme.edgeWidth / 2)
                .fill(conn.displayColor)
                .frame(width: Theme.edgeWidth, height: 26)

            // Info
            VStack(alignment: .leading, spacing: Theme.space1) {
                Text(conn.name).font(.system(size: 13, weight: .medium))
                Text(conn.displayHost)
                    .font(Theme.fontChrome)
                    .foregroundColor(.secondary)
            }

            Spacer()

            EngineBadge(engine: conn.engine)

            // Transport badge — shown only when it carries information: TCP/IP is the
            // default on nearly every row, so labeling it everywhere is just noise.
            // SSH and Socket connections are the exceptions worth calling out.
            if conn.engine != .sqlite && conn.connectionType != .tcpip {
                Text(conn.connectionType.rawValue)
                    .font(Theme.fontCaption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, Theme.space3)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusCard - 2)
                .fill(selectedIds.contains(conn.id) ? Theme.connectionTint(conn.displayColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            editingConnection = conn
        }
        .contextMenu {
            Button("Edit") {
                editingConnection = conn
            }
            Button("Connect") {
                selectedIds = [conn.id]
                Task { await connect() }
            }
            Divider()
            Button("Remove from Favorites…", role: .destructive) { removing = conn }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "star.circle")
                .font(.system(size: 52))
                .foregroundColor(.secondary.opacity(0.35))
            Text("No favorites yet")
                .font(.title3).foregroundColor(.secondary)
            Text("Click \"New Connection\" to add your first server")
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Why the last connect failed, in full on a row of its own: beside Connect the
            // panel left it a narrow column, and it was cut off.
            if let err = connectError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                    .lineLimit(10)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(err)
                    .accessibilityIdentifier("home.connectError")
                if let change = keyChange {
                    Button("Forget the Old Key and Connect…") { Task { await forgetAndConnect(change) } }
                        .controlSize(.small)
                        .accessibilityIdentifier("home.forgetHostKey")
                }
            }
            HStack(spacing: 12) {
                Spacer()
                Text(selectedIds.isEmpty ? "" : "\(selectedIds.count) selected")
                    .font(.caption).foregroundColor(.secondary)
                Button {
                    Task { await connect() }
                } label: {
                    if isConnecting {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Connecting…")
                        }
                    } else {
                        Text("Connect" + (selectedIds.isEmpty ? "" : " (\(selectedIds.count))"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedIds.isEmpty || isConnecting)
                .accessibilityIdentifier("home.connect")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func toggle(_ id: UUID) {
        if selectedIds.contains(id) { selectedIds.remove(id) }
        else { selectedIds.insert(id) }
    }

    private func connect() async {
        connectError = nil
        keyChange = nil
        isConnecting = true
        let toConnect = manager.saved.filter { selectedIds.contains($0.id) }
        do {
            try await manager.connect(toConnect)
            showWorkspace = true
        } catch {
            connectError = error.localizedDescription
            keyChange = error as? SSHHostKeyChange
        }
        isConnecting = false
    }

    /// After the user confirms the server's new key: the old one goes, and the connect runs again.
    private func forgetAndConnect(_ change: SSHHostKeyChange) async {
        guard SSHLoginPrompt.confirmForget(change) else { return }
        do { try manager.forgetHostKey(change) } catch { connectError = error.localizedDescription; return }
        await connect()
    }

    private func fitWindowToScreen() {
        guard let screen = NSScreen.main,
              let window = NSApplication.shared.windows.first else { return }
        let available = screen.visibleFrame
        let w = min(available.width  * 0.85, 1440)
        let h = min(available.height * 0.80, 900)
        let x = available.origin.x + (available.width  - w) / 2
        let y = available.origin.y + (available.height - h) / 2
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: false)
    }
}