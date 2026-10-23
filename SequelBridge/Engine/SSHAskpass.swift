//
//  SSHAskpass.swift
//  SequelBridge
//
//  Answers the questions ssh asks while it logs in: a password, a key's passphrase, a
//  one-time code from an RSA token or an authenticator app. The tunnel runs ssh without
//  a terminal, so ssh runs `scriptURL` for each question (SSH_ASKPASS, forced). The
//  script sends the question with this login's one-time token to a listener on
//  127.0.0.1 and prints the answer `ask` returns; no answer (the dialog's Cancel) fails
//  that login attempt. The script ships inside the app (sb-askpass): the sandbox won't run
//  a file the app wrote.
//

import Foundation
import Network

final class SSHAskpass {
    let scriptURL: URL
    /// What ssh's environment needs so it asks through the script.
    private(set) var environment: [String: String] = [:]
    /// A question got no answer: the login failed because the user cancelled it.
    private(set) var cancelled = false
    /// A question is waiting for its answer; the tunnel's connect timeout pauses meanwhile.
    private(set) var isAsking = false

    private let token = UUID().uuidString + UUID().uuidString
    private let listener: NWListener
    private let ask: @MainActor (String) async -> String?

    init(ask: @escaping @MainActor (String) async -> String?) async throws {
        self.ask = ask
        guard let helper = Self.helperURL else {
            throw SequelBridgeError.attachFailed("The app's askpass helper (sb-askpass) is missing: reinstall SequelBridge.")
        }
        scriptURL = helper

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.serve(connection) }
        }
        let started = Once()
        let port = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:         if started.claim() { c.resume(returning: listener.port?.rawValue ?? 0) }
                    case .failed(let e): if started.claim() { c.resume(throwing: e) }
                    case .cancelled:     if started.claim() { c.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
        environment = [
            "SSH_ASKPASS": scriptURL.path,
            "SSH_ASKPASS_REQUIRE": "force",   // no terminal: every question goes to the script
            "DISPLAY": ":0",                   // an older ssh uses SSH_ASKPASS only with a DISPLAY
            "SB_ASKPASS_PORT": String(port),
            "SB_ASKPASS_TOKEN": token,
        ]
    }

    /// The askpass program inside the app (Resources/sb-askpass).
    nonisolated static var helperURL: URL? { Bundle.main.url(forResource: "sb-askpass", withExtension: nil) }

    func stop() {
        listener.cancel()
    }

    // MARK: - One question per connection: the token line, the question in base64

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                let lines = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                if lines.count >= 3 {
                    self.answer(connection, token: String(decoding: lines[0], as: UTF8.self),
                                question: String(decoding: lines[1], as: UTF8.self))
                } else if isComplete || error != nil || buffer.count > 64 * 1024 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func answer(_ connection: NWConnection, token: String, question: String) {
        guard token == self.token, let decoded = Data(base64Encoded: question) else { connection.cancel(); return }
        let prompt = String(decoding: decoded, as: UTF8.self)
        isAsking = true
        Task { @MainActor in
            let reply = await self.ask(prompt)
            self.isAsking = false
            guard let reply else { self.cancelled = true; connection.cancel(); return }
            connection.send(content: Data((reply + "\n").utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// Settles a continuation once, whichever listener state arrives first.
private final class Once {
    private var done = false
    func claim() -> Bool { if done { return false }; done = true; return true }
}
