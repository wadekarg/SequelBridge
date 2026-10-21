//  SSHTunnel.swift — SSH local port-forwarding tunnel via /usr/bin/ssh

import AppKit
import Foundation
import Darwin

/// Manages one `ssh -N -L` process that forwards a local port to a database server.
/// Usage: create → start(conn:) → connect to localPort → stop() when done.
final class SSHTunnel {
    private(set) var localPort: Int
    private var process: Process?
    private var stderr: DrainedPipe?
    /// Called on the main actor when ssh ends while the tunnel was meant to run: the Mac
    /// slept, the network dropped, the server restarted. Not after `stop()`.
    var onDrop: (() -> Void)?
    private var stopping = false
    /// ssh's process id while it runs (the tests end it to stand in for a dropped network).
    var processIdentifier: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }
    private var askpass: SSHAskpass?

    /// Answers what ssh asks while it logs in: a password, a key's passphrase, a one-time
    /// code. The app sets it to its login dialog; while it is nil, ssh runs in BatchMode
    /// and a login that needs an answer fails.
    static var prompter: ((SSHLoginRequest) async -> String?)?

    /// Where ssh remembers servers' keys: nil for ssh's own ~/.ssh/known_hosts, shared with
    /// Terminal. A test or UI test passes a throwaway file (-SBKnownHostsFile).
    static var knownHostsFile: String?

    /// The -SBKnownHostsFile path among the launch arguments, if there is one.
    static func knownHostsFile(from arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "-SBKnownHostsFile"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// Host → the fingerprint of the new key the user confirmed when forgetting the old
    /// one: the next login trusts that key, and only that key, without asking again.
    static var trusted: [String: String] = [:]

    /// Forgets the key remembered for `change`'s server (`ssh-keygen -R`, which keeps the
    /// file as it was beside it, ending .old) and trusts the key the server sent now, which
    /// the user confirmed, for the next login.
    static func forget(_ change: SSHHostKeyChange) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-R", change.key.host, "-f", change.knownHostsFile]
        let errors = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        try p.run()
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw SequelBridgeError.attachFailed("Couldn't forget the old key: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        trusted[change.key.host] = change.key.fingerprint
    }

    /// Every tunnel whose ssh is running. A child process outlives its parent on macOS,
    /// so without this an ssh left open at quit kept its SSH session and local port
    /// alive, reparented to launchd, until the server went away.
    private static var running: [ObjectIdentifier: Process] = [:]
    private static let quitObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SSHTunnel.stopAll() }
        }

    /// Ends every running tunnel; the app calls it when it quits.
    static func stopAll() {
        for process in running.values { process.terminate() }
        running.removeAll()
    }

    init() {
        self.localPort = Self.findAvailablePort()
    }

    /// Where a tunnel goes: the SSH server and login, and the database behind it. A
    /// connection's database switch reuses its tunnel only when this is unchanged.
    struct Route: Equatable {
        let sshHost: String, sshPort: Int, sshUser: String, sshKey: String, host: String, port: Int
        init(_ c: Connection) {
            sshHost = c.sshHost; sshPort = c.sshPort; sshUser = c.sshUsername; sshKey = c.sshKeyPath
            host = c.host; port = c.port
        }
    }

    /// The route this tunnel was started for; nil before `start`.
    private(set) var route: Route?

    /// Whether ssh still runs (a dropped network or a restarted server ends it).
    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Lifecycle

    func start(conn: Connection) async throws {
        let expandedKey = conn.sshKeyPath.isEmpty
            ? nil
            : (conn.sshKeyPath as NSString).expandingTildeInPath

        // A key path the user typed but that does not exist must fail loudly.
        // Otherwise ssh silently falls back to the agent or a default key, and a
        // misconfigured connection "works" until the day that fallback is gone.
        if let key = expandedKey, !FileManager.default.fileExists(atPath: key) {
            throw SequelBridgeError.attachFailed("SSH key not found at \(key)")
        }

        let p = Process()
        let counts = AskCounts()
        if let prompter = Self.prompter {
            askpass = try await SSHAskpass { prompt in
                guard !counts.cancelled else { return nil }
                let kind = SSHLogin.kind(of: prompt)
                // The new key the user confirmed when forgetting the old one: trusted unasked.
                if kind == .hostKey, let key = SSHHostKey(newServerPrompt: prompt), Self.trusted[key.host] == key.fingerprint {
                    return "yes"
                }
                let request = SSHLoginRequest(prompt: prompt, kind: kind, timesAsked: counts.next(kind),
                                              user: conn.sshUsername, host: conn.sshHost, connectionID: conn.id)
                let reply = await prompter(request)
                // Cancel on a password or a code: ssh would ask again, up to three times, so
                // the login ends. On a key's passphrase, ssh moves on to the next way in.
                if reply == nil, SSHLogin.cancelEndsLogin(kind) {
                    counts.cancelled = true
                    counts.untrusted = kind == .hostKey
                    p.terminate()
                }
                return reply
            }
        }

        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = Self.arguments(for: conn, localPort: localPort, keyPath: expandedKey, interactive: askpass != nil)
        if let askpass {
            // No terminal: ssh asks every question through the askpass script.
            p.environment = ProcessInfo.processInfo.environment.merging(askpass.environment) { $1 }
            p.standardInput = FileHandle.nullDevice
        }
        // stdout is genuinely unwanted, so discard it outright — an undrained Pipe
        // would eventually fill and block ssh. stderr is kept, but drained
        // continuously for the same reason: a tunnel that reconnects or emits
        // keepalive warnings for hours would otherwise fill 64KB and freeze.
        p.standardOutput = FileHandle.nullDevice
        let stderrPipe = DrainedPipe()
        p.standardError = stderrPipe.pipe
        self.stderr = stderrPipe

        try p.run()
        self.process = p
        self.route = Route(conn)
        _ = Self.quitObserver
        Self.running[ObjectIdentifier(self)] = p

        // Poll until the local port is listening: 10 seconds, not counting the time a
        // question from ssh waits for its answer.
        var waited = 0
        while waited < 20 {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
            if isLocalPortListening(localPort) {
                endLogin()
                // From now on an end of ssh is a dropped tunnel, which the workspace reports.
                p.terminationHandler = { [weak self] _ in
                    Task { @MainActor in
                        guard let self, !self.stopping else { return }
                        Self.running.removeValue(forKey: ObjectIdentifier(self))
                        self.onDrop?()
                    }
                }
                return
            }
            if !p.isRunning {
                Self.running.removeValue(forKey: ObjectIdentifier(self))
                endLogin()
                let msg = stderrPipe.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let change = SSHHostKeyChange(sshOutput: msg) { throw change }
                if counts.untrusted {
                    throw SequelBridgeError.attachFailed("The SSH server's key wasn't trusted, so SequelBridge didn't connect.")
                }
                if counts.cancelled { throw SequelBridgeError.attachFailed("SSH login cancelled.") }
                throw SequelBridgeError.attachFailed(
                    "SSH process exited unexpectedly.\(msg.isEmpty ? "" : " \(msg)")\n\nCheck: SSH host, username, key path and password.")
            }
            if !(askpass?.isAsking ?? false) { waited += 1 }
        }
        p.terminate()
        Self.running.removeValue(forKey: ObjectIdentifier(self))
        endLogin()
        throw SequelBridgeError.attachFailed(
            "SSH tunnel timed out after 10 seconds. Verify the SSH host is reachable and the key is valid.")
    }

    /// The ssh command line for the tunnel: a local forward to the database through the
    /// SSH server. `interactive` when the app answers ssh's questions (SSHAskpass).
    ///
    /// `+ssh-rsa` appends SHA-1 RSA to the algorithms ssh accepts, for the server's host
    /// key and for signatures made with an RSA user key. OpenSSH 8.8 and later switched
    /// both off, which locks out servers running OpenSSH 7.1 and older: they offer their
    /// host key only as ssh-rsa ("no matching host key type found. Their offer: ssh-rsa")
    /// and accept only ssh-rsa signatures. Appended, it is used only when the server
    /// offers nothing newer.
    static func arguments(for conn: Connection, localPort: Int, keyPath: String?, interactive: Bool = false) -> [String] {
        // An IPv6 address is bracketed, or ssh reads its colons as the forward's own.
        let target = conn.host.contains(":") && !conn.host.hasPrefix("[") ? "[\(conn.host)]" : conn.host
        var args: [String] = [
            "-N",                                               // no remote command
            "-L", "\(localPort):\(target):\(conn.port)",       // forward local→remote database
            "-p", "\(conn.sshPort)",                           // SSH server port
            // A server not met before: the app asks whether to trust its key, as ssh does in
            // Terminal; with nothing to answer (a script, a test), it's trusted as before.
            "-o", "StrictHostKeyChecking=\(interactive ? "ask" : "accept-new")",
            "-o", "ExitOnForwardFailure=yes",                  // die if tunnel can't bind
            "-o", "ServerAliveInterval=30",                    // keepalive
            "-o", "ConnectTimeout=10",                         // SSH connect timeout
            // An ssh of its own, whatever ~/.ssh/config says: under a ControlMaster, a
            // second tunnel through the same server lived in the first one's ssh, and went
            // when that one was closed.
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "HostKeyAlgorithms=+ssh-rsa",                // old servers' host keys
            "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",         // old servers' key logins
        ]
        // With nothing to answer them, ssh must not wait on questions (a password, a
        // key's passphrase, a one-time code); with SSHAskpass, the app answers.
        if !interactive { args += ["-o", "BatchMode=yes"] }
        if let file = knownHostsFile { args += ["-o", "UserKnownHostsFile=\(file)"] }
        if let keyPath {
            // IdentitiesOnly=yes: use ONLY this key, never the agent or defaults,
            // so the connection depends on exactly the key the user chose.
            args += ["-i", keyPath, "-o", "IdentitiesOnly=yes"]
        }
        args.append("\(conn.sshUsername)@\(conn.sshHost)")
        return args
    }

    /// The login is over, one way or the other: ssh asks nothing more.
    private func endLogin() {
        askpass?.stop()
        askpass = nil
    }

    func stop() {
        stopping = true
        endLogin()
        process?.terminate()
        process = nil
        Self.running.removeValue(forKey: ObjectIdentifier(self))
        stderr?.stop()
        stderr = nil
    }

    // MARK: - Port helpers

    /// Tries a blocking connect to 127.0.0.1:port. Returns true if something is listening.
    private func isLocalPortListening(_ port: Int) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = CFSwapInt16HostToBig(UInt16(port))
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Finds an unused local port in the 13307-13500 range.
    // The range local forward ports are drawn from.
    static let portRange = 13307...13999

    /// A free local port for the forward. The range is scanned from a random
    /// start so two tunnels opened at nearly the same moment — or two test worker
    /// processes — do not race onto the same number. No SO_REUSEADDR: the bind
    /// must reflect real availability, or a busy port would look free.
    static func findAvailablePort() -> Int {
        let lo = portRange.lowerBound, hi = portRange.upperBound
        let span = hi - lo + 1
        let start = Int.random(in: 0..<span)
        for i in 0..<span {
            let port = lo + (start + i) % span
            if isPortFree(port) { return port }
        }
        return lo
    }

    private static func isPortFree(_ port: Int) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = CFSwapInt16HostToBig(UInt16(port))
        addr.sin_addr.s_addr = INADDR_ANY
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

/// How often each kind of question was asked in one login, and whether it was cancelled.
private final class AskCounts {
    var cancelled = false
    var untrusted = false          // the cancelled question was whether to trust a new server
    private var counts: [SSHLogin.Kind: Int] = [:]
    func next(_ kind: SSHLogin.Kind) -> Int {
        defer { counts[kind, default: 0] += 1 }
        return counts[kind, default: 0]
    }
}
