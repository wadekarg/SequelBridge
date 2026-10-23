//
//  SandboxCheck.swift
//  SequelBridge
//
//  The App Store build's self-check (scripts/check-appstore-sandbox.sh): launched with
//  -SBSandboxCheck and opened with folders (which grants them, as an open panel would), it
//  runs the app's own SSH and SQLite code in the sandbox, on the paths the script names
//  (-SBCheckSSHFolder, -SBCheckSQLite) and never the user's own ~/.ssh, writes a report to
//  its container's temporary folder, then quits. Compiled into the App Store build only.
//

#if APP_STORE
import AppKit
import Foundation

@MainActor
enum SandboxCheck {
    static func value(_ flag: String, _ offset: Int = 1, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + offset < args.count else { return nil }
        return args[i + offset]
    }

    static func run(arguments args: [String], opened: [URL]) async {
        guard let name = value("-SBSandboxCheck", in: args) else { return }
        opened.forEach { Grants.shared.add($0) }
        var report: [String: String] = [:]
        report["sandboxed"] = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil ? "yes" : "no"
        let sparkle = NSClassFromString("SPUUpdater") != nil
            || FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Contents/Frameworks/Sparkle.framework")
        report["sparkle"] = sparkle ? "present" : "absent"
        report["sockets"] = DatabaseEngine.mysql.connectionTypes.contains(.socket) ? "offered" : "not offered"
        // Only the paths the script names, granted by opening them or by an earlier launch:
        // never the user's own ~/.ssh, even in an App Store build that has it granted.
        if let folder = value("-SBCheckSSHFolder", in: args), Grants.shared.covering(folder) != nil,
           let host = value("-SBCheckSSH", in: args), let port = value("-SBCheckSSH", 2, in: args).flatMap(Int.init),
           let user = value("-SBCheckSSH", 3, in: args), let target = value("-SBCheckTarget", in: args) {
            let ssh = URL(fileURLWithPath: folder, isDirectory: true)
            SSHTunnel.sshFolderGrant = { ssh }
            // In place of the app's login dialog: the stand-in's known_hosts starts empty, so
            // the server's key is trusted (and ssh writes it there), and the key's passphrase.
            let phrase = value("-SBCheckPassphrase", in: args)
            SSHTunnel.prompter = { request in
                switch request.kind {
                case .hostKey: return "yes"
                case .passphrase: return phrase
                default: return nil
                }
            }
            report["ssh.key"] = await tunnel(host: host, port: port, user: user, target: target, key: folder + "/key")
            report["ssh.passphrase"] = await tunnel(host: host, port: port, user: user, target: target, key: folder + "/phrase_key")
            SSHTunnel.prompter = nil
        }
        if let file = value("-SBCheckSQLite", in: args), Grants.shared.covering(file) != nil {
            let (duck, tool) = await sqlite(file)
            report["sqlite.duckdb"] = duck
            report["sqlite.sqlite3"] = tool
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: url)
        NSApp.terminate(nil)
    }

    /// An SSH tunnel through the real SSHTunnel, checked end to end: the first bytes from the
    /// forward's target.
    static func tunnel(host: String, port: Int, user: String, target: String, key: String) async -> String {
        let parts = target.split(separator: ":")
        var c = Connection(name: "check", alias: "check", connectionType: .ssh,
                           host: String(parts[0]), port: Int(parts[1]) ?? 22, username: "x")
        c.sshHost = host; c.sshPort = port; c.sshUsername = user; c.sshKeyPath = key
        let t = SSHTunnel()
        do {
            try await t.start(conn: c)
            defer { t.stop() }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(t.localPort).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
            var buf = [UInt8](repeating: 0, count: 32)
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let n = ok ? read(fd, &buf, buf.count) : -1
            return n > 0 ? "tunnel works (\(n) bytes from \(target))" : "no bytes through the tunnel"
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    /// The SQLite file written in-process (DuckDB) and by macOS's sqlite3 (the Query tab's route
    /// for statements newer than DuckDB's SQLite).
    static func sqlite(_ path: String) async -> (String, String) {
        var c = Connection(name: "check", alias: "check")
        c.engine = .sqlite
        c.database = path
        do {
            let engine = try QueryEngine()
            try await engine.attach(c, password: "")
            defer { Task { try? await engine.detach("check") } }
            try await engine.executeDDL(alias: "check", sql: "INSERT INTO t VALUES (1)")
            try await SQLiteTool.run("INSERT INTO t VALUES (2)", file: path, busyTimeout: 5)
            let counted = try await SQLiteTool.query("SELECT count(*) FROM t", file: path, busyTimeout: 5)
            return ("written", "written (\(counted.rows.first?.first.flatMap { $0 } ?? "?") rows)")
        } catch {
            return ("failed: \(error.localizedDescription)", "not run")
        }
    }
}
#endif
