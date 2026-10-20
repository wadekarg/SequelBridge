//
//  WireLink.swift
//  SequelBridge
//
//  The byte stream under the app's own MySQL and PostgreSQL clients: plain TCP or a Unix
//  socket through Network.framework, or TCP that switches to TLS part-way.
//

import Foundation
import Network

nonisolated enum WireLinkError: LocalizedError, CustomStringConvertible {
    case connection(String)
    case protocolError(String)
    var description: String {
        switch self {
        case .connection(let m), .protocolError(let m): return m
        }
    }
    /// The message itself wherever the error is shown, not "The operation couldn't be completed".
    var errorDescription: String? { description }
}

/// Bytes to and from the server, whichever way they travel.
protocol WireLink: AnyObject {
    func send(_ data: Data) async throws
    /// Exactly `n` bytes, or an error.
    func receive(_ n: Int) async throws -> Data
    func close()
}

/// Plain TCP or a Unix socket, through Network.framework.
final class NWWireLink: WireLink {
    private let conn: NWConnection
    init(_ conn: NWConnection) { self.conn = conn }

    /// Opens the TCP or Unix-socket connection. A refused or unreachable server fails at
    /// once (Network.framework would otherwise wait for the network to change), and
    /// nothing waits longer than `timeout`.
    static func connect(host: String, port: Int, socketPath: String?, timeout: TimeInterval) async throws -> NWConnection {
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let conn: NWConnection
        if let path = socketPath {
            conn = NWConnection(to: .unix(path: path), using: params)
        } else {
            conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any,
                using: params)
        }
        let target = socketPath ?? "\(host):\(port)"
        let queue = DispatchQueue(label: "SequelBridge.WireLink")   // serial: one resume, never two
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let attempt = ConnectAttempt(conn, cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: attempt.settle(nil)
                case .failed(let e), .waiting(let e):
                    attempt.settle(WireLinkError.connection("Could not connect to \(target): \(e.localizedDescription)"))
                case .cancelled: attempt.settle(WireLinkError.connection("Connection to \(target) cancelled"))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                attempt.settle(WireLinkError.connection("Timed out connecting to \(target)"))
            }
            conn.start(queue: queue)
        }
        return conn
    }

    /// Ends a connect attempt exactly once, whichever comes first: ready, a failure, or the
    /// timeout. Every caller runs on the connection's one serial queue.
    private nonisolated final class ConnectAttempt: @unchecked Sendable {
        private let conn: NWConnection
        private let cont: CheckedContinuation<Void, Error>
        private var settled = false
        init(_ conn: NWConnection, _ cont: CheckedContinuation<Void, Error>) { self.conn = conn; self.cont = cont }
        func settle(_ error: Error?) {
            guard !settled else { return }
            settled = true
            conn.stateUpdateHandler = nil
            if let error { conn.cancel(); cont.resume(throwing: error) } else { cont.resume() }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: WireLinkError.connection(err.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    func receive(_ n: Int) async throws -> Data {
        guard n > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, err in
                if let err { cont.resume(throwing: WireLinkError.connection(err.localizedDescription)); return }
                guard let data, data.count == n else {
                    cont.resume(throwing: WireLinkError.protocolError("Short read (\(data?.count ?? 0)/\(n))")); return
                }
                cont.resume(returning: data)
            }
        }
    }

    func close() { conn.cancel() }
}

/// TCP that switches to TLS part-way, which both protocols' SSL needs (each asks for it
/// in plain text) and Network.framework can't do: a URLSession stream task, whose
/// startSecureConnection() does exactly that. Like the app's other connections (MySQL's
/// ssl_mode=required, libpq's sslmode=require), it encrypts without checking the
/// server's certificate.
final class TLSWireLink: NSObject, WireLink, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let timeout: TimeInterval
    private var session: URLSession?
    private var stream: URLSessionStreamTask?

    init(host: String, port: Int, timeout: TimeInterval) {
        self.host = host; self.port = port; self.timeout = timeout
        super.init()
    }

    /// The stream task, made on first use: its session needs this object as delegate.
    private var live: URLSessionStreamTask {
        if let stream { return stream }
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let t = s.streamTask(withHostName: host, port: port)
        t.resume()
        session = s; stream = t
        return t
    }

    func send(_ data: Data) async throws {
        let stream = live
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stream.write(data, timeout: timeout) { err in
                if let err { cont.resume(throwing: WireLinkError.connection(err.localizedDescription)) }
                else { cont.resume() }
            }
        }
    }

    func receive(_ n: Int) async throws -> Data {
        guard n > 0 else { return Data() }
        let stream = live
        var out = Data()
        while out.count < n {
            let chunk: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                stream.readData(ofMinLength: 1, maxLength: n - out.count, timeout: timeout) { data, atEOF, err in
                    if let err { cont.resume(throwing: WireLinkError.connection(err.localizedDescription)); return }
                    guard let data, !data.isEmpty else {
                        cont.resume(throwing: WireLinkError.protocolError(atEOF ? "The server closed the connection." : "Short read"))
                        return
                    }
                    cont.resume(returning: data)
                }
            }
            out.append(chunk)
        }
        return out
    }

    /// Switches to TLS once the writes and reads already queued are done.
    func startTLS() { live.startSecureConnection() }

    func close() {
        stream?.cancel()
        session?.invalidateAndCancel()
    }

    // ssl_mode=required: encrypted, the certificate not checked.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        accept(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        accept(challenge, completionHandler)
    }

    private func accept(_ challenge: URLAuthenticationChallenge,
                        _ completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
