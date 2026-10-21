//
//  PostgresClient.swift
//  SequelBridge
//
//  PostgreSQL's own wire protocol, for the statements postgres_scanner can't run:
//  postgres_query nests every query as a subquery (SELECT … FROM (query)), and
//  PostgreSQL takes neither EXPLAIN nor SHOW there, nor in any function a query can
//  call. One connection per call: startup, login (SCRAM-SHA-256, MD5 or a password),
//  one simple query, close. SSL as libpq's sslmode does it: required when the
//  connection has Use SSL ticked, otherwise used when the server offers it; like the
//  app's other PostgreSQL connection (sslmode=require), it encrypts without checking
//  the server's certificate.
//

import Foundation
import CryptoKit
import CommonCrypto

final class PostgresClient {

    struct Config {
        let host: String
        let port: Int
        let user: String
        let password: String
        let database: String
        let useTLS: Bool
        /// The directory holding a Unix socket (libpq's host=/dir), instead of host and port.
        var socketDirectory: String? = nil
        /// A read-only connection's sessions start read-only on the server.
        var readOnly = false
    }

    enum PostgresClientError: LocalizedError, CustomStringConvertible {
        case server(String)
        case protocolError(String)
        var description: String {
            switch self {
            case .server(let m), .protocolError(let m): return m
            }
        }
        var errorDescription: String? { description }
    }

    static let connectTimeout: TimeInterval = 10
    static let copyInRefusal = "COPY … FROM STDIN needs data sent along with it, which the Query tab doesn't do: use Import CSV in the table's menu."
    static let sslMissing = "The server doesn't offer SSL, and this connection has Use SSL ticked, so it wasn't asked anything."

    private let config: Config
    init(_ config: Config) { self.config = config }

    /// Runs one statement and returns its columns and rows (NULL → nil); with several
    /// statements, the last result. Opens, logs in, queries and closes a connection.
    func query(_ sql: String) async throws -> (columns: [String], rows: [[String?]]) {
        let link = try await open()
        defer { link.close() }
        return try await link.cancellable {
            try await startup(link)
            link.allowSlowReplies()
            let result = try await simpleQuery(link, sql)
            try? await link.send(Self.message("X", Data()))
            return result
        }
    }

    /// Runs `statements` one after another on one connection, each as a query of its own
    /// (one message with several runs them as one transaction, where VACUUM, CREATE INDEX
    /// CONCURRENTLY and CREATE DATABASE can't run), and returns the last one's result. A
    /// failure stops there and says which statement it was when there are several.
    func run(_ statements: [String], setup: [String] = []) async throws -> (columns: [String], rows: [[String?]]) {
        let link = try await open()
        defer { link.close() }
        return try await link.cancellable {
            try await startup(link)
            link.allowSlowReplies()
            // The app's own statements first (the schema picked), outside the numbering.
            for sql in setup { _ = try await simpleQuery(link, sql) }
            var last: (columns: [String], rows: [[String?]]) = ([], [])
            for (n, sql) in statements.enumerated() {
                do { last = try await simpleQuery(link, sql) }
                catch where statements.count > 1 && !Task.isCancelled {
                    throw PostgresClientError.server("Statement \(n + 1) of \(statements.count): \(error.localizedDescription)")
                }
            }
            try? await link.send(Self.message("X", Data()))
            return last
        }
    }

    // MARK: - Connection

    private func open() async throws -> WireLink {
        if let dir = config.socketDirectory {
            let path = (dir as NSString).appendingPathComponent(".s.PGSQL.\(config.port)")
            return NWWireLink(try await NWWireLink.connect(host: config.host, port: config.port,
                                                          socketPath: path, timeout: Self.connectTimeout))
        }
        // SSLRequest goes first, in plain text; 'S' means TLS from the next byte on.
        let link = TLSWireLink(host: config.host, port: config.port, timeout: Self.connectTimeout)
        do {
            try await link.send(Self.int32(8) + Self.int32(80_877_103))
            let answer = try await link.receive(1)
            if answer.first == UInt8(ascii: "S") {
                link.startTLS()
            } else if config.useTLS {
                throw PostgresClientError.server(Self.sslMissing)
            }
            return link
        } catch {
            link.close()
            throw error
        }
    }

    private func startup(_ link: WireLink) async throws {
        var params = [("user", config.user), ("database", config.database.isEmpty ? config.user : config.database),
                      ("application_name", "SequelBridge"), ("client_encoding", "UTF8")]
        if config.readOnly { params.append(("default_transaction_read_only", "on")) }
        var body = Self.int32(196_608)   // protocol 3.0
        for (key, value) in params { body += Self.cstring(key) + Self.cstring(value) }
        body.append(0)
        try await link.send(Self.int32(Int32(body.count + 4)) + body)

        var scram: SCRAM? = nil
        while true {
            let (type, payload) = try await Self.readMessage(link)
            switch type {
            case UInt8(ascii: "R"):
                let code = payload.count >= 4 ? Self.readInt32(payload, 0) : -1
                switch code {
                case 0: break                                       // AuthenticationOk
                case 3:                                             // a password, as is
                    try await link.send(Self.message("p", Self.cstring(config.password)))
                case 5:                                             // MD5, salted
                    let salt = payload.subdata(in: 4..<8)
                    try await link.send(Self.message("p", Self.cstring(Self.md5Password(user: config.user, password: config.password, salt: salt))))
                case 10:                                            // SASL: the mechanisms on offer
                    let offered = Self.cstrings(payload.subdata(in: 4..<payload.count))
                    guard offered.contains("SCRAM-SHA-256") else {
                        throw PostgresClientError.protocolError("The server offers \(offered.joined(separator: ", ")) to log in; the app speaks SCRAM-SHA-256.")
                    }
                    let s = SCRAM(user: "", password: config.password)
                    scram = s
                    let first = Data(s.clientFirst.utf8)
                    try await link.send(Self.message("p", Self.cstring("SCRAM-SHA-256") + Self.int32(Int32(first.count)) + first))
                case 11:                                            // SASL: the server's first message
                    guard var s = scram else { throw PostgresClientError.protocolError("SCRAM went out of order.") }
                    let final = try s.clientFinal(String(decoding: payload.subdata(in: 4..<payload.count), as: UTF8.self))
                    scram = s
                    try await link.send(Self.message("p", Data(final.utf8)))
                case 12:                                            // SASL: the server proves it knew the password
                    guard let s = scram else { throw PostgresClientError.protocolError("SCRAM went out of order.") }
                    try s.verify(String(decoding: payload.subdata(in: 4..<payload.count), as: UTF8.self))
                default:
                    throw PostgresClientError.protocolError(
                        "The server asks for a way to log in the app doesn't speak (code \(code)); a password, MD5 and SCRAM-SHA-256 work.")
                }
            case UInt8(ascii: "E"):
                throw PostgresClientError.server(Self.errorMessage(payload))
            case UInt8(ascii: "Z"):
                return
            default:
                continue                                            // ParameterStatus, BackendKeyData, a notice
            }
        }
    }

    private func simpleQuery(_ link: WireLink, _ sql: String) async throws -> (columns: [String], rows: [[String?]]) {
        try await link.send(Self.message("Q", Self.cstring(sql)))
        var columns: [String] = []
        var rows: [[String?]] = []
        var failure: Error? = nil
        while true {
            let (type, payload) = try await Self.readMessage(link)
            switch type {
            case UInt8(ascii: "T"):
                columns = Self.rowDescription(payload)
                rows = []
            case UInt8(ascii: "D"):
                rows.append(Self.dataRow(payload))
            case UInt8(ascii: "G"):
                // COPY … FROM STDIN waits for data the app has none of: refused, so the
                // statement ends at once (it hung until Cancel).
                try await link.send(Self.message("f", Self.cstring(Self.copyInRefusal)))
            case UInt8(ascii: "H"):
                columns = ["COPY"]                                  // COPY … TO STDOUT: its lines
                rows = []
            case UInt8(ascii: "d"):
                var line = String(decoding: payload, as: UTF8.self)
                if line.hasSuffix("\n") { line.removeLast() }
                rows.append([line])
            case UInt8(ascii: "E"):
                failure = PostgresClientError.server(Self.errorMessage(payload))
            case UInt8(ascii: "Z"):
                if let failure { throw failure }
                return (columns, rows)
            default:
                continue                                            // CommandComplete, EmptyQuery, a notice
            }
        }
    }

    // MARK: - Messages

    static func message(_ type: Character, _ body: Data) -> Data {
        Data([type.asciiValue ?? 0]) + int32(Int32(body.count + 4)) + body
    }

    static func readMessage(_ link: WireLink) async throws -> (UInt8, Data) {
        let head = try await link.receive(5)
        let length = Int(readInt32(head, 1))
        guard length >= 4 else { throw PostgresClientError.protocolError("The server sent a broken message.") }
        return (head[head.startIndex], Data(try await link.receive(length - 4)))
    }

    static func int32(_ v: Int32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    static func readInt32(_ d: Data, _ at: Int) -> Int32 {
        let i = d.startIndex + at
        return Int32(bitPattern: UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3]))
    }

    static func readInt16(_ d: Data, _ at: Int) -> Int {
        let i = d.startIndex + at
        return Int(Int16(bitPattern: UInt16(d[i]) << 8 | UInt16(d[i + 1])))
    }

    static func cstring(_ s: String) -> Data { Data(s.utf8) + Data([0]) }

    /// NUL-terminated strings, up to an empty one or the end.
    static func cstrings(_ d: Data) -> [String] {
        d.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The column names in a RowDescription.
    static func rowDescription(_ d: Data) -> [String] {
        var names: [String] = []
        var i = d.startIndex + 2
        for _ in 0..<max(0, readInt16(d, 0)) {
            guard let end = d[i...].firstIndex(of: 0) else { break }
            names.append(String(decoding: d[i..<end], as: UTF8.self))
            i = end + 1 + 18                                        // table oid, column, type oid, size, modifier, format
        }
        return names
    }

    /// A DataRow's values, as text; nil for NULL.
    static func dataRow(_ d: Data) -> [String?] {
        var values: [String?] = []
        var i = 2
        for _ in 0..<max(0, readInt16(d, 0)) {
            let length = Int(readInt32(d, i))
            i += 4
            if length < 0 { values.append(nil); continue }
            let start = d.startIndex + i
            values.append(String(decoding: d[start..<(start + length)], as: UTF8.self))
            i += length
        }
        return values
    }

    /// An ErrorResponse's message, with its detail and hint when it has them.
    static func errorMessage(_ d: Data) -> String {
        var fields: [UInt8: String] = [:]
        var i = d.startIndex
        while i < d.endIndex, d[i] != 0 {
            let code = d[i]
            guard let end = d[(i + 1)...].firstIndex(of: 0) else { break }
            fields[code] = String(decoding: d[(i + 1)..<end], as: UTF8.self)
            i = end + 1
        }
        var message = fields[UInt8(ascii: "M")] ?? "PostgreSQL refused the statement."
        if let detail = fields[UInt8(ascii: "D")] { message += " \(detail)" }
        if let hint = fields[UInt8(ascii: "H")] { message += " \(hint)" }
        return message
    }

    // MARK: - Logins

    /// "md5" + md5(md5(password + user) + salt), in hex.
    static func md5Password(user: String, password: String, salt: Data) -> String {
        func hex(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        return "md5" + hex(Data(hex(Data((password + user).utf8)).utf8) + salt)
    }

    /// SCRAM-SHA-256 (RFC 5802, 7677) without channel binding. PostgreSQL ignores the
    /// user name in it (the startup message names the user), so it goes empty.
    struct SCRAM {
        let user: String
        let password: String
        let clientNonce: String
        private(set) var serverSignature = Data()

        init(user: String, password: String, clientNonce: String? = nil) {
            self.user = user
            self.password = password
            self.clientNonce = clientNonce ?? Data((0..<18).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        }

        var clientFirstBare: String { "n=\(user),r=\(clientNonce)" }
        var clientFirst: String { "n,," + clientFirstBare }

        mutating func clientFinal(_ serverFirst: String) throws -> String {
            var parts: [Character: String] = [:]
            for item in serverFirst.split(separator: ",") where item.count > 2 {
                parts[item.first!] = String(item.dropFirst(2))
            }
            guard let nonce = parts["r"], nonce.hasPrefix(clientNonce),
                  let saltText = parts["s"], let salt = Data(base64Encoded: saltText),
                  let iterations = parts["i"].flatMap(Int.init), iterations > 0 else {
                throw PostgresClientError.protocolError("The server's SCRAM reply didn't make sense.")
            }
            let salted = Self.pbkdf2(password.precomposedStringWithCompatibilityMapping, salt: salt, iterations: iterations)
            let clientKey = Self.hmac(salted, "Client Key")
            let storedKey = Data(SHA256.hash(data: clientKey))
            let withoutProof = "c=biws,r=\(nonce)"
            let authMessage = "\(clientFirstBare),\(serverFirst),\(withoutProof)"
            let signature = Self.hmac(storedKey, authMessage)
            let proof = Data(zip(clientKey, signature).map { $0 ^ $1 })
            serverSignature = Self.hmac(Self.hmac(salted, "Server Key"), authMessage)
            return "\(withoutProof),p=\(proof.base64EncodedString())"
        }

        func verify(_ serverFinal: String) throws {
            guard serverFinal == "v=\(serverSignature.base64EncodedString())" else {
                throw PostgresClientError.protocolError("The server couldn't prove it knows the password, so the app stopped.")
            }
        }

        static func hmac(_ key: Data, _ text: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
        }

        static func pbkdf2(_ password: String, salt: Data, iterations: Int) -> Data {
            var out = [UInt8](repeating: 0, count: 32)
            let secret = Array(password.utf8).map { CChar(bitPattern: $0) }
            salt.withUnsafeBytes { saltBytes in
                _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret, secret.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, out.count)
            }
            return Data(out)
        }
    }
}
