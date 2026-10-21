//
//  SSHLoginTests.swift
//  SequelBridgeTests
//
//  The SSH tunnel ran ssh with BatchMode, key-only: a server that asked for a password,
//  a key's passphrase, or a one-time code from an RSA token got no answer, and the login
//  failed. A tester could not connect that way. ssh now hands each question to a small
//  script (SSH_ASKPASS), the script hands it to the app over 127.0.0.1 with a one-time
//  token, and the app answers. These need no SSH server.
//

import AppKit
import Foundation
import Testing
@testable import SequelBridge

@Suite("SSH login: what ssh asks, and how it is answered")
struct SSHLoginTests {

    @Test("a question is a key's passphrase, a password, or a one-time code")
    func kinds() {
        #expect(SSHLogin.kind(of: "Enter passphrase for key '/Users/me/.ssh/id_rsa': ") == .passphrase)
        #expect(SSHLogin.kind(of: "tunneluser@bastion.example.com's password: ") == .password)
        #expect(SSHLogin.kind(of: "Password: ") == .password)
        #expect(SSHLogin.kind(of: "Verification code: ") == .code)
        #expect(SSHLogin.kind(of: "Enter PASSCODE: ") == .code)
        #expect(SSHLogin.kind(of: "Duo two-factor login for me\n\nPasscode or option (1-2): ") == .code)
        // A one-time code that calls itself a password is still a code: never saved, never reused.
        #expect(SSHLogin.kind(of: "One-time password (OATH) for `me': ") == .code)
        #expect(SSHLogin.kind(of: "Enter your OTP password: ") == .code)
        #expect(SSHLogin.kind(of: "Token password: ") == .code)
        // A server never met before: whether to trust its key.
        #expect(SSHLogin.kind(of: Self.newServerPrompt) == .hostKey)
        // ssh's own password question names the host, whatever the host is called.
        #expect(SSHLogin.kind(of: "me@otp-gateway.example.com's password: ") == .password)
        #expect(SSHLogin.kind(of: "me@token.example.com's password: ") == .password)
    }

    @Test("a saved password or passphrase answers the first time; asked again, the user is asked; codes are never saved")
    func savedAnswers() {
        #expect(SSHLogin.answer(kind: .password, timesAsked: 0, saved: "pw") == .use("pw"))
        #expect(SSHLogin.answer(kind: .password, timesAsked: 1, saved: "pw") == .ask)
        #expect(SSHLogin.answer(kind: .passphrase, timesAsked: 0, saved: "pp") == .use("pp"))
        #expect(SSHLogin.answer(kind: .password, timesAsked: 0, saved: nil) == .ask)
        #expect(SSHLogin.answer(kind: .code, timesAsked: 0, saved: "123456") == .ask)
    }

    @Test("Cancel on a key's passphrase skips that key; Cancel on a password or a code ends the login")
    func cancelRules() {
        // ssh moves on to the next key or the password after a skipped passphrase, but asks
        // a password or a code again, up to three times.
        #expect(!SSHLogin.cancelEndsLogin(.passphrase))
        #expect(SSHLogin.cancelEndsLogin(.password))
        #expect(SSHLogin.cancelEndsLogin(.code))
    }

    /// Runs the askpass script the way ssh does: the question as its one argument, the
    /// answer on stdout. Awaited, so the listener on the main queue keeps running.
    @MainActor
    private func runScript(_ askpass: SSHAskpass, prompt: String, environment: [String: String]? = nil)
        async throws -> (stdout: String, status: Int32) {
        let p = Process()
        p.executableURL = askpass.scriptURL
        p.arguments = [prompt]
        p.environment = environment ?? ProcessInfo.processInfo.environment.merging(askpass.environment) { $1 }
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (text, p.terminationStatus)
    }

    @MainActor @Test("ssh's question reaches the app through the script, and the answer comes back")
    func roundTrip() async throws {
        var asked: [String] = []
        let askpass = try await SSHAskpass { prompt in asked.append(prompt); return "answer to \(prompt.count)" }
        defer { askpass.stop() }
        let prompt = "Duo two-factor login\n\nPasscode: "
        let r = try await runScript(askpass, prompt: prompt)
        #expect(asked == [prompt])
        #expect(r.stdout == "answer to \(prompt.count)\n")
        #expect(r.status == 0)
        // ssh uses the script for every question, with no terminal to fall back on.
        #expect(askpass.environment["SSH_ASKPASS"] == askpass.scriptURL.path)
        #expect(askpass.environment["SSH_ASKPASS_REQUIRE"] == "force")
    }

    @MainActor @Test("a wrong token gets no answer and the app is never asked")
    func wrongToken() async throws {
        var asked = 0
        let askpass = try await SSHAskpass { _ in asked += 1; return "secret" }
        defer { askpass.stop() }
        var env = ProcessInfo.processInfo.environment.merging(askpass.environment) { $1 }
        env["SB_ASKPASS_TOKEN"] = "not-the-token"
        let r = try await runScript(askpass, prompt: "Password: ", environment: env)
        #expect(asked == 0)
        #expect(r.stdout.isEmpty)
        #expect(r.status != 0)
    }

    @MainActor @Test("Cancel in the dialog fails that login attempt")
    func cancelled() async throws {
        let askpass = try await SSHAskpass { _ in nil }
        defer { askpass.stop() }
        let r = try await runScript(askpass, prompt: "Verification code: ")
        #expect(r.stdout.isEmpty)
        #expect(r.status != 0)
        #expect(askpass.cancelled)
    }

    @MainActor @Test("the login dialog has a field wide enough to type in: a password, a passphrase, a one-time code (SSHLoginUITests types into it)")
    func dialogFieldIsUsable() {
        for kind in [SSHLogin.Kind.password, .passphrase, .code] {
            let request = SSHLoginRequest(prompt: "Enter PASSCODE:", kind: kind, timesAsked: 1,
                                          user: "me", host: "203.0.113.7", connectionID: UUID())
            let dialog = SSHLoginPrompt.loginAlert(request, saved: nil)
            dialog.alert.layout()
            #expect(dialog.field.frame.width >= 200, "\(kind): the field is \(dialog.field.frame.width) points wide")
            #expect(dialog.field.frame.height >= 20, "\(kind): the field is \(dialog.field.frame.height) points high")
        }
    }

    @MainActor @Test("ssh keeps BatchMode only when nothing can answer its questions")
    func arguments() {
        var conn = Connection(name: "s", alias: "s", connectionType: .ssh, host: "db", port: 3306)
        conn.sshHost = "bastion"; conn.sshUsername = "me"
        let interactive = SSHTunnel.arguments(for: conn, localPort: 13307, keyPath: nil, interactive: true)
        #expect(!interactive.contains("BatchMode=yes"))
        let quiet = SSHTunnel.arguments(for: conn, localPort: 13307, keyPath: nil, interactive: false)
        #expect(quiet.contains("BatchMode=yes"))
    }

    static let newServerPrompt = """
        The authenticity of host '[127.0.0.1]:2224 ([127.0.0.1]:2224)' can't be established.
        ED25519 key fingerprint is SHA256:Zx9FakeFingerprintFakeFingerprintFake0123ab.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """

    /// ssh's warning for a key that changed, with a made-up host, fingerprint and path.
    static let changedKeyOutput = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
        Someone could be eavesdropping on you right now (man-in-the-middle attack)!
        It is also possible that a host key has just been changed.
        The fingerprint for the RSA key sent by the remote host is
        SHA256:Qr7FakeRSAFingerprintFakeRSAFingerprint456cd.
        Please contact your system administrator.
        Add correct host key in /Users/me/.ssh/known_hosts to get rid of this message.
        Offending ED25519 key in /Users/me/.ssh/known_hosts:112
        Host key for 203.0.113.7 has changed and you have requested strict checking.
        Host key verification failed.
        """

    @Test("a new server's question: trust its key, read from it, never saved; Cancel ends the login")
    func newServer() throws {
        let key = try #require(SSHHostKey(newServerPrompt: Self.newServerPrompt))
        #expect(key == SSHHostKey(host: "[127.0.0.1]:2224", keyType: "ED25519",
                                  fingerprint: "SHA256:Zx9FakeFingerprintFakeFingerprintFake0123ab"))
        #expect(SSHLogin.answer(kind: .hostKey, timesAsked: 0, saved: "yes") == .ask)
        #expect(SSHLogin.cancelEndsLogin(.hostKey))
        #expect(SSHHostKey(newServerPrompt: "Password: ") == nil)
        // OpenSSH 10's wording: "fingerprint is:" and no full stop.
        let ssh10 = Self.newServerPrompt.replacingOccurrences(
            of: "fingerprint is SHA256:Zx9FakeFingerprintFakeFingerprintFake0123ab.",
            with: "fingerprint is: SHA256:Zx9FakeFingerprintFakeFingerprintFake0123ab")
        #expect(SSHHostKey(newServerPrompt: ssh10)?.fingerprint == "SHA256:Zx9FakeFingerprintFakeFingerprintFake0123ab")
    }

    @Test("a changed key, read out of ssh's warning: the host, the key it sent, and the line holding the old one")
    func changedKey() throws {
        let change = try #require(SSHHostKeyChange(sshOutput: Self.changedKeyOutput))
        #expect(change.key == SSHHostKey(host: "203.0.113.7", keyType: "RSA",
                                         fingerprint: "SHA256:Qr7FakeRSAFingerprintFakeRSAFingerprint456cd"))
        #expect(change.knownHostsFile == "/Users/me/.ssh/known_hosts")
        #expect(change.line == 112)
        // Said plainly: which server, which key, where the old one is, and what to do.
        let message = change.localizedDescription
        for part in ["203.0.113.7", "SHA256:Qr7FakeRSAFingerprintFakeRSAFingerprint456cd", "line 112", "forget the old key"] {
            #expect(message.contains(part), "\(part) not in: \(message)")
        }
        #expect(!message.contains("@@@@"), "ssh's banner is in the message")
        #expect(SSHHostKeyChange(sshOutput: "Permission denied (publickey).") == nil)
    }
}
