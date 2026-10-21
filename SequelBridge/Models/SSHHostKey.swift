//
//  SSHHostKey.swift
//  SequelBridge
//
//  A server's SSH key, as ssh shows it when it meets a server for the first time (the
//  login asks whether to trust it) and when a server's key isn't the one remembered for
//  it (ssh stops: "REMOTE HOST IDENTIFICATION HAS CHANGED").
//

import Foundation

/// A server's key: the host as ssh names it ("db.example", or "[127.0.0.1]:2224" on a
/// port other than 22), the key's type and its SHA256 fingerprint.
nonisolated struct SSHHostKey: Equatable, Sendable {
    let host: String
    let keyType: String
    let fingerprint: String

    init(host: String, keyType: String, fingerprint: String) {
        self.host = host; self.keyType = keyType; self.fingerprint = fingerprint
    }

    /// From ssh's question about a server it hasn't met: "The authenticity of host
    /// 'HOST (ADDRESS)' can't be established. TYPE key fingerprint is SHA256:…. Are you
    /// sure you want to continue connecting (yes/no/[fingerprint])?" (OpenSSH 10 writes
    /// "fingerprint is: SHA256:…", without the full stop.)
    init?(newServerPrompt prompt: String) {
        guard let host = SSHText.first(#"authenticity of host '([^' ]+)"#, in: prompt).first,
              case let key = SSHText.first(#"(\S+) key fingerprint is:?\s+(SHA256:[A-Za-z0-9+/]+)"#, in: prompt),
              key.count == 2 else { return nil }
        self.init(host: host, keyType: key[0], fingerprint: key[1])
    }
}

/// The login stopped because a server's key isn't the one remembered for it. `key` is the
/// key the server sent now; `knownHostsFile` and `line` hold the old one.
nonisolated struct SSHHostKeyChange: Error, LocalizedError, Equatable, Sendable {
    let key: SSHHostKey
    let knownHostsFile: String
    let line: Int?

    init?(sshOutput out: String) {
        guard out.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"),
              case let sent = SSHText.first(#"fingerprint for the (\S+) key sent by the remote host is:?\s+(SHA256:[A-Za-z0-9+/]+)"#, in: out),
              sent.count == 2,
              let host = SSHText.first(#"Host key for (\S+) has changed"#, in: out).first else { return nil }
        let offending = SSHText.first(#"Offending \S+ key in (.+):(\d+)"#, in: out)
        guard let file = offending.first ?? SSHText.first(#"Add correct host key in (.+) to get rid of this message"#, in: out).first
        else { return nil }
        key = SSHHostKey(host: host, keyType: sent[0], fingerprint: sent[1])
        knownHostsFile = file
        line = offending.count == 2 ? Int(offending[1]) : nil
    }

    var errorDescription: String? {
        let file = (knownHostsFile as NSString).abbreviatingWithTildeInPath
        let place = line.map { "on line \($0) of \(file)" } ?? "in \(file)"
        return "\(key.host)'s SSH key has changed: it sent \(key.keyType) \(key.fingerprint), not the key remembered "
            + "\(place), so the login stopped before any password was sent. A rebuilt server does this, and so can "
            + "someone listening in between: if whoever runs the server confirms the new key, forget the old key and connect."
    }
}

/// Captures of the first match of a pattern.
nonisolated enum SSHText {
    static func first(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
