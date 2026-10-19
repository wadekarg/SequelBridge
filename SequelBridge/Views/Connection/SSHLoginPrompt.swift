//
//  SSHLoginPrompt.swift
//  SequelBridge
//
//  The dialog for what ssh asks while it logs in: a password, a key's passphrase, or a
//  one-time code from an RSA token or an authenticator app. It shows the server's own
//  question. A password or passphrase saved with "Remember in Keychain" answers the
//  first time it is asked; a one-time code is never saved.
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
        case .code:       return nil
        }
    }

    static func answer(_ request: SSHLoginRequest) async -> String? {
        let kind = keychainKind(request.kind)
        let saved = kind.flatMap { Keychain.load(for: request.connectionID, kind: $0) }
        if case .use(let value) = SSHLogin.answer(kind: request.kind, timesAsked: request.timesAsked, saved: saved) {
            return value
        }

        let alert = NSAlert()
        alert.messageText = "SSH login to \(request.user)@\(request.host)"
        let question = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = request.timesAsked > 0 ? "That didn't work. \(question)" : question
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        let stack = NSStackView(views: [field])
        stack.orientation = .vertical
        stack.alignment = .leading
        var remember: NSButton?
        if kind != nil {
            let box = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
            box.state = saved == nil ? .off : .on
            stack.addArrangedSubview(box)
            remember = box
        }
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: remember == nil ? 24 : 50)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        if let kind, let remember {
            if remember.state == .on { Keychain.save(value, for: request.connectionID, kind: kind) }
            else { Keychain.delete(for: request.connectionID, kind: kind) }
        }
        return value
    }
}
