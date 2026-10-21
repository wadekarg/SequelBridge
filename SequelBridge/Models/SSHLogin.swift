//
//  SSHLogin.swift
//  SequelBridge
//
//  What ssh asks while it logs in, and how the app answers it.
//

import Foundation

nonisolated enum SSHLogin {
    enum Kind: Equatable, Hashable, Sendable { case password, passphrase, code, hostKey }
    enum Answer: Equatable { case use(String), ask }

    /// What a question from ssh asks for. "Enter passphrase for key '…':" is a key's
    /// passphrase and "user@host's password:" a password; anything else ("Verification
    /// code:", "Enter PASSCODE:", a two-factor menu) is a one-time code.
    static func kind(of prompt: String) -> Kind {
        let p = prompt.lowercased()
        // A server ssh hasn't met: whether to trust its key.
        if p.contains("authenticity of host") || p.contains("continue connecting") { return .hostKey }
        if p.contains("passphrase") { return .passphrase }
        // ssh's own question, "user@host's password:", whatever the host is called.
        if p.range(of: #"^\s*[^\s@]+@[^\s']+'s password:\s*$"#, options: .regularExpression) != nil { return .password }
        // A one-time code that calls itself a password ("One-time password:", "OTP
        // password:") is still a code, so it is never saved and never sent again.
        let oneTime = ["one-time", "one time", "otp", "token", "verification", "passcode", "authenticator"]
        if oneTime.contains(where: { p.contains($0) }) { return .code }
        if p.contains("password") { return .password }
        return .code
    }

    /// Whether Cancel on this question ends the whole login. ssh asks a password or a code
    /// again (up to three times), so Cancel ends it; a key's passphrase is asked once, and
    /// skipping it moves ssh on to the next key or the password.
    static func cancelEndsLogin(_ kind: Kind) -> Bool { kind != .passphrase }

    /// A saved password or passphrase answers the first time it is asked in a login.
    /// Asked again in the same login, the saved one was wrong, so the user is asked. A
    /// one-time code is never saved.
    static func answer(kind: Kind, timesAsked: Int, saved: String?) -> Answer {
        guard kind == .password || kind == .passphrase, timesAsked == 0, let saved else { return .ask }
        return .use(saved)
    }
}

/// One question ssh asked while logging in to `user`@`host` for a connection.
struct SSHLoginRequest: Sendable, Equatable {
    let prompt: String
    let kind: SSHLogin.Kind
    let timesAsked: Int          // how often this kind was asked before in this login
    let user: String
    let host: String
    let connectionID: UUID
}
