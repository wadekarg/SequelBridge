//
//  AddConnectionSheet.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import SwiftUI

// MARK: - Preset colors (used in both sheet and sidebar)

struct ConnectionColors {
    static let presets: [(name: String, hex: String)] = [
        ("Blue",    "#4A90D9"),
        ("Green",   "#27AE60"),
        ("Orange",  "#E67E22"),
        ("Red",     "#E74C3C"),
        ("Purple",  "#9B59B6"),
        ("Teal",    "#1ABC9C"),
        ("Pink",    "#E91E8C"),
        ("Yellow",  "#F39C12"),
        ("Indigo",  "#3F51B5"),
        ("Coral",   "#FF6B6B"),
        ("Brown",   "#795548"),
        ("Slate",   "#607D8B"),
    ]
}

// MARK: - Inline color picker

struct ColorDotPicker: View {
    @Binding var selectedHex: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ConnectionColors.presets, id: \.hex) { preset in
                let isSelected = selectedHex.uppercased() == preset.hex.uppercased()
                Circle()
                    .fill(Color(hex: preset.hex) ?? .blue)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.8), lineWidth: isSelected ? 2.5 : 0)
                            .padding(-3)
                    )
                    .shadow(color: .black.opacity(isSelected ? 0.25 : 0), radius: 2)
                    .onTapGesture { selectedHex = preset.hex }
                    .help(preset.name)
                    .animation(.easeInOut(duration: 0.1), value: isSelected)
            }
        }
    }
}

// MARK: - Main sheet

struct AddConnectionSheet: View {
    @EnvironmentObject private var manager: ConnectionManager
    @Binding var isPresented: Bool
    var editingConnection: Connection? = nil
    var onConnect: (() -> Void)? = nil

    @State private var name: String
    @State private var alias: String
    @State private var color: String
    @State private var connectionType: ConnectionType
    @State private var engine: DatabaseEngine
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var database: String
    @State private var sshHost: String
    @State private var sshPort: String
    @State private var sshUsername: String
    @State private var sshKeyPath: String
    @State private var socketPath: String
    @State private var useSSL: Bool
    @State private var folder: String
    @State private var readOnly: Bool
    @State private var testStatus: TestStatus = .idle
    /// The id of the connection being made, the same for Test Connection and Add to
    /// Favorites: a password the test's SSH login kept in the Keychain belongs to the
    /// connection saved after it (each made an id of its own, so it belonged to neither).
    @State private var draftID = UUID()
    @State private var testError: String?
    @State private var saveError: String?

    private var isEditing: Bool { editingConnection != nil }

    enum TestStatus { case idle, testing, success, failure }

    // Pre-fill fields immediately so the sheet never flashes empty on first render
    init(isPresented: Binding<Bool>, editingConnection: Connection? = nil, onConnect: (() -> Void)? = nil) {
        self._isPresented = isPresented
        self.editingConnection = editingConnection
        self.onConnect = onConnect
        let c = editingConnection
        _name           = State(initialValue: c?.name           ?? "")
        _alias          = State(initialValue: c?.alias          ?? "")
        _color          = State(initialValue: c?.color          ?? ConnectionColors.presets[0].hex)
        // A saved type the engine does not offer (a ClickHouse socket) never worked: show TCP/IP.
        let savedEngine = c?.engine ?? .mysql
        let savedType = c?.connectionType ?? .tcpip
        _connectionType = State(initialValue: savedEngine.connectionTypes.contains(savedType) ? savedType : .tcpip)
        _engine         = State(initialValue: savedEngine)
        _host           = State(initialValue: c?.host           ?? "")
        _port           = State(initialValue: c.map { String($0.port) } ?? String(DatabaseEngine.mysql.defaultPort))
        _username       = State(initialValue: c?.username       ?? "")
        _password       = State(initialValue: c.flatMap { Keychain.load(for: $0.id) } ?? "")
        _database       = State(initialValue: c?.database       ?? "")
        _sshHost        = State(initialValue: c?.sshHost        ?? "")
        _sshPort        = State(initialValue: c.map { String($0.sshPort) } ?? "22")
        _sshUsername    = State(initialValue: c?.sshUsername    ?? "")
        _sshKeyPath     = State(initialValue: c?.sshKeyPath     ?? "")
        _socketPath     = State(initialValue: c?.socketPath     ?? DatabaseEngine.mysql.defaultSocketPath)
        _useSSL         = State(initialValue: c?.useSSL         ?? false)
        _folder         = State(initialValue: c?.folder         ?? "")
        _readOnly       = State(initialValue: c?.readOnly       ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            HStack {
                Text(isEditing ? "Edit Connection" : "New Connection")
                    .font(.title2).bold()
                Spacer()
                Button {
                    if isEditing { autoSave() }
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Name + Alias
                    nameAliasSection

                    // Color picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color").font(.caption).foregroundColor(.secondary)
                        ColorDotPicker(selectedHex: $color)
                    }

                    // Which database product is on the other end
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Database").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: $engine) {
                            ForEach(DatabaseEngine.allCases) { e in
                                Text(e.displayName).tag(e)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: engine) { _, newEngine in
                            // Follow the new engine's default port, unless the port
                            // was deliberately set to something non-standard.
                            if port.isEmpty || DatabaseEngine.allCases.contains(where: { String($0.defaultPort) == port }) {
                                port = String(newEngine.defaultPort)
                            }
                            // The same for the socket path, and keep the connection type
                            // to one the new engine offers (ClickHouse has no socket).
                            if socketPath.isEmpty || DatabaseEngine.allCases.contains(where: { $0.defaultSocketPath == socketPath }) {
                                socketPath = newEngine.defaultSocketPath
                            }
                            if !newEngine.isFileBased && !newEngine.connectionTypes.contains(connectionType) {
                                connectionType = .tcpip
                            }
                        }
                    }

                    // Connection type — meaningless for a local file
                    if !engine.isFileBased {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connection Type").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: $connectionType) {
                            ForEach(engine.connectionTypes, id: \.self) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    }

                    // Type-specific fields
                    if engine.isFileBased {
                        sqliteFields
                    } else {
                        switch connectionType {
                        case .tcpip:  tcpipFields
                        case .ssh:    sshFields
                        case .socket: socketFields
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Test status
            if testStatus != .idle {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if testStatus == .testing {
                            ProgressView().scaleEffect(0.7)
                            Text("Testing connection…").font(.caption).foregroundColor(.secondary)
                        } else if testStatus == .success {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Connection successful").font(.caption).foregroundColor(.green)
                        } else {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                            Text("Connection failed").font(.caption).foregroundColor(.red)
                        }
                    }
                    if let err = testError {
                        Text(err).font(.caption).foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if testStatus == .failure, let change = manager.hostKeyChange {
                        Button("Forget the Old Key and Test Again…") { Task { await forgetAndTest(change) } }
                            .controlSize(.small)
                            .accessibilityIdentifier("connection.forgetHostKey")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            if let err = saveError {
                Text(err).foregroundColor(.red).font(.caption)
                    .padding(.horizontal, 20).padding(.bottom, 4)
            }

            // Footer buttons
            HStack {
                Button("Test Connection") { Task { await runTest() } }
                    .disabled(testStatus == .testing || !isFormValid)

                Spacer()

                Button("Cancel") {
                    // A new connection not saved: what its test's login kept goes too.
                    if editingConnection == nil {
                        for kind in SSHLoginPrompt.keychainKinds { Keychain.delete(for: draftID, kind: kind) }
                    }
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                if isEditing {
                    Button("Save Changes") {
                        autoSave()
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isFormValid)
                    Button("Connect") {
                        autoSave()
                        isPresented = false
                        onConnect?()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isFormValid)
                } else {
                    Button("Add to Favorites") {
                        addToFavorites()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isFormValid)
                }
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    // MARK: - Field sections

    private var nameAliasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundColor(.secondary)
                    TextField("e.g. Production DB", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alias").font(.caption).foregroundColor(.secondary)
                    TextField("e.g. db12", text: $alias)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .help("Short ID used in queries — no spaces")
                    if aliasConflict {
                        Text("Alias already in use")
                            .font(.caption2).foregroundColor(.red)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder").font(.caption).foregroundColor(.secondary)
                    TextField("optional", text: $folder)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .help("Groups this connection on the home screen")
                }
            }
            Toggle(isOn: $readOnly) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Read-only (safe mode)")
                        Text("Block all writes — INSERT, UPDATE, DELETE and DDL — on this connection")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    @ViewBuilder
    private var tcpipFields: some View {
        formGroup("Server") {
            row("Host",     field: TextField("192.168.1.1", text: $host))
            row("Port",     field: TextField(String(engine.defaultPort), text: $port).frame(width: 80))
            row("Username", field: TextField(engine == .postgres ? "postgres" : "root", text: $username))
            row("Password", field: SecureField("required", text: $password))
            row("Database", field: TextField("optional — select after connecting", text: $database))
            row("SSL",      field: Toggle("", isOn: $useSSL).labelsHidden()
                                    .help("Required for AWS RDS, Azure, PlanetScale and other cloud databases"))
        }
    }

    @ViewBuilder
    private var sshFields: some View {
        formGroup("SSH Tunnel") {
            row("SSH Host",     field: TextField("ssh.example.com", text: $sshHost))
            row("SSH Port",     field: TextField("22", text: $sshPort).frame(width: 80))
            row("SSH Username", field: TextField("ubuntu", text: $sshUsername))
            row("SSH Key", field: HStack(spacing: 6) {
                TextField("optional, e.g. ~/.ssh/id_rsa", text: $sshKeyPath)
                    .help("Leave it empty to log in with a password. A password, a key's passphrase or a one-time code is asked when you connect.")
                if Distribution.current.needsGrants {
                    // The App Store build: picking the key grants it to the sandbox.
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.directoryURL = URL(fileURLWithPath: Paths.realHome + "/.ssh", isDirectory: true)
                        panel.showsHiddenFiles = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            Grants.shared.add(url)
                            sshKeyPath = url.path
                        }
                    }
                    .controlSize(.small)
                }
            })
        }
        formGroup("\(engine.displayName) Server") {
            row("Host",     field: TextField("127.0.0.1", text: $host))
            row("Port",     field: TextField(String(engine.defaultPort), text: $port).frame(width: 80))
            row("Username", field: TextField(engine == .postgres ? "postgres" : "root", text: $username))
            row("Password", field: SecureField("required", text: $password))
            row("Database", field: TextField("optional", text: $database))
            // Through the tunnel too: an SSL-only server (RDS, Azure) behind a bastion.
            row("SSL",      field: Toggle("", isOn: $useSSL).labelsHidden()
                                    .help("Encrypt the database connection inside the tunnel too: AWS RDS, Azure and other cloud databases need it"))
        }
        HStack {
            Image(systemName: "info.circle").foregroundColor(.secondary)
            Text(Distribution.current.offersSSHAgent
                 ? "With SSH Key blank, ssh uses your usual keys and ssh-agent, or a password. Whatever the server asks "
                   + "(a password, a key's passphrase, a one-time code) is asked when you connect."
                 : "With SSH Key blank, ssh uses your usual keys in ~/.ssh, or a password (the App Store version can't use "
                   + "ssh-agent). Whatever the server asks (a password, a key's passphrase, a one-time code) is asked when you connect.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var socketFields: some View {
        formGroup("Socket") {
            // PostgreSQL takes the socket's directory (or the .s.PGSQL.<port> file itself).
            row(engine == .postgres ? "Socket Directory" : "Socket Path",
                field: TextField(engine.defaultSocketPath, text: $socketPath))
            // PostgreSQL names its socket file after the port: .s.PGSQL.5432.
            if engine == .postgres {
                row("Port", field: TextField(String(engine.defaultPort), text: $port).frame(width: 80))
            }
            row("Username",    field: TextField("root", text: $username))
            row("Password",    field: SecureField("required", text: $password))
            row("Database",    field: TextField("optional", text: $database))
        }
    }

    private func formGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundColor(.secondary)
            VStack(spacing: 6) { content() }
        }
    }

    private func row<F: View>(_ label: String, field: F) -> some View {
        HStack {
            Text(label)
                .frame(width: 86, alignment: .trailing)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            field.textFieldStyle(.roundedBorder)
            Spacer()
        }
    }

    // MARK: - SQLite

    private var sqliteFields: some View {
        formGroup("Database File") {
            row("File", field: HStack(spacing: 6) {
                TextField("~/data/app.sqlite", text: $database)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        database = url.path
                        // The App Store build: its folder too, asked now rather than at the first connect.
                        if Distribution.current.needsGrants { _ = Grants.shared.folder(holding: url.path) }
                        if name.isEmpty  { name  = url.deletingPathExtension().lastPathComponent }
                        if alias.isEmpty { alias = url.deletingPathExtension().lastPathComponent }
                    }
                }
                .controlSize(.small)
            })
        }
    }

    // MARK: - Validation

    /// Aliases key every piece of engine and workspace state (the ATTACH name,
    /// engines/directConns/sidebarTrees/selectedDatabase…), so a duplicate would
    /// collide with an existing connection. Reject it before saving.
    private var aliasConflict: Bool {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return manager.saved.contains { $0.alias == trimmed && $0.id != editingConnection?.id }
    }

    private var isFormValid: Bool {
        guard !name.isEmpty && !alias.isEmpty else { return false }
        guard !aliasConflict else { return false }
        // A SQLite file needs no username or password.
        if engine.isFileBased { return !database.isEmpty }
        guard !username.isEmpty else { return false }
        switch connectionType {
        case .tcpip:  return !host.isEmpty && Int(port) != nil
        case .ssh:    return !sshHost.isEmpty && !sshUsername.isEmpty && !host.isEmpty
        case .socket: return !socketPath.isEmpty
        }
    }

    // MARK: - Actions

    private func buildConnection() -> Connection {
        var conn = Connection(
            name: name, alias: alias,
            connectionType: connectionType,
            color: color,
            host: host, port: Int(port) ?? engine.defaultPort,
            username: username, database: database,
            sshHost: sshHost, sshPort: Int(sshPort) ?? 22,
            sshUsername: sshUsername, sshKeyPath: sshKeyPath,
            socketPath: socketPath,
            useSSL: useSSL,
            engine: engine,
            folder: folder.trimmingCharacters(in: .whitespacesAndNewlines),
            readOnly: readOnly
        )
        conn.id = editingConnection?.id ?? draftID
        return conn
    }

    private func runTest() async {
        testStatus = .testing; testError = nil
        let conn = buildConnection()
        if let err = await manager.testConnection(conn, password: password) {
            testStatus = .failure; testError = err
        } else {
            testStatus = .success
        }
    }

    /// After the user confirms the server's new key: the old one goes, and the test runs again.
    private func forgetAndTest(_ change: SSHHostKeyChange) async {
        guard SSHLoginPrompt.confirmForget(change) else { return }
        do { try manager.forgetHostKey(change) } catch { testError = error.localizedDescription; return }
        await runTest()
    }

    private func addToFavorites() {
        let conn = buildConnection()
        do {
            try manager.addSaved(conn, password: password)
            isPresented = false
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func autoSave() {
        guard let existing = editingConnection, isFormValid else { return }
        var conn = buildConnection()
        conn.id = existing.id
        try? manager.updateSaved(conn, password: password.isEmpty ? nil : password)
    }
}
