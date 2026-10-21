//
//  SSHLoginPrompt.swift
//  SequelBridge
//
//  The dialog for what ssh asks while it logs in: a password, a key's passphrase, or a
//  one-time code from an RSA token or an authenticator app. It shows the server's own
//  question. A password or passphrase saved with "Remember in Keychain" answers the
//  first time it is asked; a one-time code is never saved. And whether to trust a server
//  met for the first time, or to forget a server's old key after it changed.
//

import AppKit

@MainActor
enum SSHLoginPrompt {
    /// The Keychain kinds a connection's SSH secrets are saved under.
    nonisolated static let keychainKinds = ["ssh-password", "ssh-passphrase"]

    nonisolated static func keychainKind(_ kind: SSHLogin.Kind) -> String? {
        switch kind {
        case .password:   return "ssh-password"
        case .passphrase: return "ssh-passphrase"
        case .code, .hostKey: return nil
        }
    }

    static func answer(_ request: SSHLoginRequest) async -> String? {
        if request.kind == .hostKey { return trust(request) }
        let kind = keychainKind(request.kind)
        let saved = kind.flatMap { Keychain.load(for: request.connectionID, kind: $0) }
        if case .use(let value) = SSHLogin.answer(kind: request.kind, timesAsked: request.timesAsked, saved: saved) {
            return value
        }

        let dialog = loginAlert(request, saved: saved)
        guard dialog.alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = dialog.field.stringValue
        if let kind, let remember = dialog.remember {
            if remember.state == .on { Keychain.save(value, for: request.connectionID, kind: kind) }
            else { Keychain.delete(for: request.connectionID, kind: kind) }
        }
        return value
    }

    /// The dialog for a password, a key's passphrase or a one-time code: ssh's question, a
    /// field for the answer and, for a password or passphrase, "Remember in Keychain".
    static func loginAlert(_ request: SSHLoginRequest, saved: String?)
        -> (alert: NSAlert, field: NSSecureTextField, remember: NSButton?) {
        let alert = NSAlert()
        alert.messageText = "SSH login to \(request.user)@\(request.host)"
        let question = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = request.timesAsked > 0 ? "That didn't work. \(question)" : question
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")

        // Laid out by frames: in a stack view the field took its own width, which for an
        // empty field is none, so "Enter PASSCODE:" showed nowhere to type.
        let width: CGFloat = 300, fieldHeight: CGFloat = 24
        var remember: NSButton?
        if keychainKind(request.kind) != nil {
            let box = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
            box.state = saved == nil ? .off : .on
            box.sizeToFit()
            remember = box
        }
        let height = fieldHeight + (remember.map { 8 + $0.frame.height } ?? 0)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: height - fieldHeight, width: width, height: fieldHeight))
        container.addSubview(field)
        if let remember {
            remember.frame.origin = .zero
            container.addSubview(remember)
        }
        alert.accessoryView = container
        alert.window.initialFirstResponder = field
        return (alert, field, remember)
    }

    /// A server ssh hasn't met: its key's fingerprint, to trust it or not. "yes" is what
    /// ssh takes for trusting it.
    private static func trust(_ request: SSHLoginRequest) -> String? {
        let alert = NSAlert()
        if let key = SSHHostKey(newServerPrompt: request.prompt) {
            alert.messageText = "First connection to \(key.host)"
            alert.informativeText = "This Mac hasn't connected to this server over SSH before. Its key:\n\n"
                + "\(key.keyType) \(key.fingerprint)\n\n"
                + "Trust it if that's the server's fingerprint (whoever runs the server can tell you). It's then "
                + "remembered in \(knownHosts), as ssh in Terminal does, and not asked about again."
        } else {
            alert.messageText = "First connection to \(request.host)"
            alert.informativeText = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.addButton(withTitle: "Trust and Connect")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? "yes" : nil
    }

    /// Where ssh remembers servers' keys, as the user knows it.
    private static var knownHosts: String {
        ((SSHTunnel.knownHostsFile ?? "~/.ssh/known_hosts") as NSString).abbreviatingWithTildeInPath
    }

    /// Whether to forget a server's old key after it changed, having seen the new one.
    /// Cancel is the default: the warning can mean someone is in between.
    static func confirmForget(_ change: SSHHostKeyChange) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Forget the old key for \(change.key.host)?"
        alert.informativeText = "Only if this is the server's new key (whoever runs the server can tell you):\n\n"
            + "\(change.key.keyType) \(change.key.fingerprint)\n\n"
            + "The old key is removed from \((change.knownHostsFile as NSString).abbreviatingWithTildeInPath) (a copy of "
            + "the file as it was is kept, ending .old); then SequelBridge connects and remembers the new one."
        let forget = alert.addButton(withTitle: "Forget Old Key")
        let cancel = alert.addButton(withTitle: "Cancel")
        forget.hasDestructiveAction = true
        forget.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
