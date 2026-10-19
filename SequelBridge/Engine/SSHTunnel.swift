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
    private var askpass: SSHAskpass?

    /// Answers what ssh asks while it logs in: a password, a key's passphrase, a one-time
    /// code. The app sets it to its login dialog; while it is nil, ssh runs in BatchMode
    /// and a login that needs an answer fails.
    static var prompter: ((SSHLoginRequest) async -> String?)?

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
        if let prompter = Self.prompter {
            let counts = AskCounts()
            askpass = try await SSHAskpass { prompt in
                // After Cancel, ssh asks again (up to three times): end the login instead.
                guard !counts.cancelled else { return nil }
                let kind = SSHLogin.kind(of: prompt)
                let request = SSHLoginRequest(prompt: prompt, kind: kind, timesAsked: counts.next(kind),
                                              user: conn.sshUsername, host: conn.sshHost, connectionID: conn.id)
                let reply = await prompter(request)
                if reply == nil { counts.cancelled = true; p.terminate() }
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
        _ = Self.quitObserver
        Self.running[ObjectIdentifier(self)] = p

        // Poll until the local port is listening: 10 seconds, not counting the time a
        // question from ssh waits for its answer.
        var waited = 0
        while waited < 20 {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
            if isLocalPortListening(localPort) { endLogin(); return }
            if !p.isRunning {
                Self.running.removeValue(forKey: ObjectIdentifier(self))
                let cancelled = askpass?.cancelled ?? false
                endLogin()
                if cancelled { throw SequelBridgeError.attachFailed("SSH login cancelled.") }
                let msg = stderrPipe.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        var args: [String] = [
            "-N",                                               // no remote command
            "-L", "\(localPort):\(conn.host):\(conn.port)",   // forward local→remote database
            "-p", "\(conn.sshPort)",                           // SSH server port
            "-o", "StrictHostKeyChecking=accept-new",          // auto-accept new host keys
            "-o", "ExitOnForwardFailure=yes",                  // die if tunnel can't bind
            "-o", "ServerAliveInterval=30",                    // keepalive
            "-o", "ConnectTimeout=10",                         // SSH connect timeout
            "-o", "HostKeyAlgorithms=+ssh-rsa",                // old servers' host keys
            "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",         // old servers' key logins
        ]
        // With nothing to answer them, ssh must not wait on questions (a password, a
        // key's passphrase, a one-time code); with SSHAskpass, the app answers.
        if !interactive { args += ["-o", "BatchMode=yes"] }
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
    private var counts: [SSHLogin.Kind: Int] = [:]
    func next(_ kind: SSHLogin.Kind) -> Int {
        defer { counts[kind, default: 0] += 1 }
        return counts[kind, default: 0]
    }
}
