//
//  MySQLClient.swift
//  SequelBridge
//
//  A minimal native MySQL/MariaDB client over the wire protocol, for the handful of
//  statements DuckDB's mysql_scanner cannot run through mysql_query — EXPLAIN and
//  SHOW CREATE TABLE — because it prepares every statement to learn its result types
//  and MariaDB can't describe those. Everything else still goes through the scanner.
//
//  Scope on purpose: protocol 41; the two login methods servers use by default —
//  mysql_native_password (MariaDB, MySQL 5.7) and caching_sha2_password (MySQL 8 and
//  later), including the full caching_sha2 login (the password RSA-encrypted with the
//  server's key over TCP, in clear over a Unix socket) and a server's request to switch
//  methods; COM_QUERY with the text result protocol. One short-lived connection per call
//  (these statements are occasional). Values come back as strings, matching how the rest
//  of the app renders cells.
//

import Foundation
import Network
import CommonCrypto
import Security

nonisolated private func sha1(_ data: Data) -> Data {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &hash) }
    return Data(hash)
}

nonisolated private func sha256(_ data: Data) -> Data {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
    return Data(hash)
}

final class MySQLClient {

    struct Config {
        let host: String
        let port: Int
        let user: String
        let password: String
        let database: String
        let useTLS: Bool
        /// A Unix socket to connect through instead of host and port.
        var socketPath: String? = nil
    }

    enum MySQLClientError: LocalizedError, CustomStringConvertible {
        case connection(String)
        case server(code: Int, message: String)
        case protocolError(String)
        var description: String {
            switch self {
            case .connection(let m): return m
            case .server(_, let m):  return m
            case .protocolError(let m): return m
            }
        }
        /// The message itself wherever the error is shown, not "The operation couldn't be completed".
        var errorDescription: String? { description }
    }

    private let config: Config
    init(_ config: Config) { self.config = config }

    /// How the last login went: which method, and for caching_sha2_password whether the
    /// server had the password cached (fast) or needed the password itself (full).
    enum AuthPath: Equatable { case nativePassword, cachingSha2Fast, cachingSha2Full }
    private(set) var authPath: AuthPath? = nil
    /// True when the server asked the client to switch login methods during the last login.
    private(set) var switchedPlugin = false

    // MARK: - Public

    /// What a connection marked "Use SSL" gets: MySQL switches to TLS inside the protocol,
    /// after its plain-text greeting, which this client doesn't do yet.
    static let sslUnsupported = "The app's own MySQL client, which runs EXPLAIN and reads the server's CREATE TABLE, can't use SSL yet, so neither is available on a connection with Use SSL ticked."

    /// Runs one text-protocol query and returns its columns + rows (NULL → nil).
    /// Opens, authenticates, queries, and closes a fresh connection each call.
    func query(_ sql: String) async throws -> (columns: [String], rows: [[String?]]) {
        // Never in clear on a connection the user asked to encrypt.
        if config.useTLS && config.socketPath == nil { throw MySQLClientError.connection(Self.sslUnsupported) }
        let conn = try await connect()
        defer { conn.cancel() }
        try await handshake(conn)
        return try await comQuery(conn, sql)
    }

    // MARK: - Connection

    /// Opens the TCP or Unix-socket connection. A refused or unreachable server fails at
    /// once (Network.framework would otherwise wait for the network to change), and
    /// nothing waits longer than `connectTimeout`.
    private func connect() async throws -> NWConnection {
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let conn: NWConnection
        if let path = config.socketPath {
            conn = NWConnection(to: .unix(path: path), using: params)
        } else {
            conn = NWConnection(
                host: NWEndpoint.Host(config.host),
                port: NWEndpoint.Port(rawValue: UInt16(config.port)) ?? 3306,
                using: params)
        }
        let target = config.socketPath ?? "\(config.host):\(config.port)"
        let queue = DispatchQueue(label: "SequelBridge.MySQLClient")   // serial: one resume, never two
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let attempt = ConnectAttempt(conn, cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: attempt.settle(nil)
                case .failed(let e), .waiting(let e):
                    attempt.settle(MySQLClientError.connection("Could not connect to \(target): \(e.localizedDescription)"))
                case .cancelled: attempt.settle(MySQLClientError.connection("Connection to \(target) cancelled"))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + Self.connectTimeout) {
                attempt.settle(MySQLClientError.connection("Timed out connecting to \(target)"))
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

    private static let connectTimeout: TimeInterval = 10

    // MARK: - Raw packet IO (3-byte length + 1-byte sequence + payload)

    private func sendRaw(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: MySQLClientError.connection(err.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    private func recvExact(_ conn: NWConnection, _ n: Int) async throws -> Data {
        guard n > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, err in
                if let err { cont.resume(throwing: MySQLClientError.connection(err.localizedDescription)); return }
                guard let data, data.count == n else {
                    cont.resume(throwing: MySQLClientError.protocolError("Short read (\(data?.count ?? 0)/\(n))")); return
                }
                cont.resume(returning: data)
            }
        }
    }

    /// Reads one protocol packet; returns (payload, sequenceId).
    private func readPacket(_ conn: NWConnection) async throws -> (Data, UInt8) {
        let header = try await recvExact(conn, 4)
        let len = Int(header[0]) | (Int(header[1]) << 8) | (Int(header[2]) << 16)
        let seq = header[3]
        let payload = try await recvExact(conn, len)
        return (payload, seq)
    }

    private func writePacket(_ conn: NWConnection, _ payload: Data, seq: UInt8) async throws {
        var out = Data(capacity: payload.count + 4)
        let len = payload.count
        out.append(UInt8(len & 0xff)); out.append(UInt8((len >> 8) & 0xff)); out.append(UInt8((len >> 16) & 0xff))
        out.append(seq)
        out.append(payload)
        try await sendRaw(conn, out)
    }

    // MARK: - Handshake + auth

    private func handshake(_ conn: NWConnection) async throws {
        let (greeting, seq) = try await readPacket(conn)
        if greeting.first == 0xff { throw Self.parseError(greeting) }
        var p = ByteReader(greeting)
        _ = p.u8()                                  // protocol version (10)
        _ = p.cString()                             // server version
        _ = p.u32()                                 // connection id
        var scramble = Data(p.bytes(8))             // auth-plugin-data part 1
        _ = p.u8()                                  // filler
        let capLow = p.u16()
        _ = p.u8()                                  // charset
        _ = p.u16()                                 // status
        let capHigh = p.u16()
        let capabilities = UInt32(capLow) | (UInt32(capHigh) << 16)
        let authDataLen = Int(p.u8())               // length of auth-plugin-data
        _ = p.bytes(10)                             // reserved
        if capabilities & CLIENT_SECURE_CONNECTION != 0 {
            let rest = max(13, authDataLen - 8)
            var tail = Data(p.bytes(rest))
            if tail.last == 0 { tail.removeLast() } // drop null terminator
            scramble.append(tail)
        }
        // The login method the server announces. caching_sha2_password (MySQL 8) is
        // answered in kind; anything else gets mysql_native_password, and the server
        // switches the client if the account needs another method.
        let announced = (capabilities & CLIENT_PLUGIN_AUTH != 0) ? p.cString() : Self.native
        var plugin = announced == Self.sha2 ? Self.sha2 : Self.native
        var nonce = Data(scramble.prefix(20))
        authPath = nil
        switchedPlugin = false

        // Build the handshake response.
        var flags: UInt32 = CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH
            | CLIENT_LONG_PASSWORD | CLIENT_TRANSACTIONS | CLIENT_LONG_FLAG
        if !config.database.isEmpty { flags |= CLIENT_CONNECT_WITH_DB }

        var resp = Data()
        resp.appendLE(flags)
        resp.appendLE(UInt32(16_777_216))           // max packet size
        resp.append(45)                             // charset utf8mb4_general_ci
        resp.append(Data(repeating: 0, count: 23))  // reserved
        resp.append(Data(config.user.utf8)); resp.append(0)
        let authResp = authResponse(plugin, nonce)
        resp.append(UInt8(authResp.count)); resp.append(authResp)
        if !config.database.isEmpty { resp.append(Data(config.database.utf8)); resp.append(0) }
        resp.append(Data(plugin.utf8)); resp.append(0)

        try await writePacket(conn, resp, seq: seq &+ 1)

        // The exchange ends in OK or an error; between them the server may switch the
        // method (0xFE) or, for caching_sha2_password, say the cached fast path worked
        // (0x01 0x03) or ask for the password itself (0x01 0x04).
        for _ in 0..<8 {
            let (reply, rseq) = try await readPacket(conn)
            switch reply.first {
            case 0x00:
                if authPath == nil { authPath = plugin == Self.sha2 ? .cachingSha2Fast : .nativePassword }
                return
            case 0xff:
                throw Self.parseError(reply)
            case 0xfe:
                var r = ByteReader(reply)
                _ = r.u8()
                let requested = r.cString()
                var data = Data(r.remaining())
                if data.last == 0 { data.removeLast() }
                guard requested == Self.native || requested == Self.sha2 else {
                    throw MySQLClientError.protocolError("The server asked for the '\(requested)' login method, which this client doesn't support.")
                }
                plugin = requested
                nonce = data
                switchedPlugin = true
                try await writePacket(conn, authResponse(plugin, nonce), seq: rseq &+ 1)
            case 0x01 where plugin == Self.sha2 && reply.count >= 2 && reply[1] == 0x03:
                authPath = .cachingSha2Fast                 // OK follows
            case 0x01 where plugin == Self.sha2 && reply.count >= 2 && reply[1] == 0x04:
                authPath = .cachingSha2Full
                if config.socketPath != nil {
                    // A Unix socket is a secure channel: the password goes in clear.
                    try await writePacket(conn, Data(config.password.utf8) + Data([0]), seq: rseq &+ 1)
                } else {
                    // Plain TCP: ask for the server's RSA key and send the password encrypted with it.
                    try await writePacket(conn, Data([0x02]), seq: rseq &+ 1)
                    let (keyPacket, kseq) = try await readPacket(conn)
                    if keyPacket.first == 0xff { throw Self.parseError(keyPacket) }
                    guard keyPacket.first == 0x01,
                          let pem = String(data: keyPacket.dropFirst(), encoding: .utf8),
                          let encrypted = Self.rsaEncryptedPassword(config.password, nonce: nonce, publicKeyPEM: pem) else {
                        throw MySQLClientError.protocolError("The server's public key for the login couldn't be read.")
                    }
                    try await writePacket(conn, encrypted, seq: kseq &+ 1)
                }
            default:
                throw MySQLClientError.protocolError("Unexpected reply during login.")
            }
        }
        throw MySQLClientError.protocolError("The login didn't finish.")
    }

    private static let native = "mysql_native_password"
    private static let sha2 = "caching_sha2_password"

    private func authResponse(_ plugin: String, _ nonce: Data) -> Data {
        plugin == Self.sha2
            ? Self.cachingSha2Scramble(password: config.password, nonce: nonce)
            : Self.nativePasswordScramble(password: config.password, scramble: nonce)
    }

    /// mysql_native_password: SHA1(pwd) XOR SHA1(scramble + SHA1(SHA1(pwd))).
    nonisolated static func nativePasswordScramble(password: String, scramble: Data) -> Data {
        guard !password.isEmpty else { return Data() }
        let h1 = sha1(Data(password.utf8))
        let h2 = sha1(h1)
        var seed = Data(scramble.prefix(20)); seed.append(h2)
        let h3 = sha1(seed)
        return Data(zip(h1, h3).map { $0 ^ $1 })
    }

    /// caching_sha2_password: SHA256(pwd) XOR SHA256(SHA256(SHA256(pwd)) + nonce).
    nonisolated static func cachingSha2Scramble(password: String, nonce: Data) -> Data {
        guard !password.isEmpty else { return Data() }
        let h1 = sha256(Data(password.utf8))
        let h2 = sha256(h1)
        var seed = h2; seed.append(nonce.prefix(20))
        let h3 = sha256(seed)
        return Data(zip(h1, h3).map { $0 ^ $1 })
    }

    /// caching_sha2_password's full login over plain TCP: the password and a NUL, XORed
    /// with the nonce (repeated), RSA-OAEP (SHA-1) encrypted with the server's public key,
    /// which MySQL sends as PEM SubjectPublicKeyInfo. nil when the key can't be read.
    nonisolated static func rsaEncryptedPassword(_ password: String, nonce: Data, publicKeyPEM: String) -> Data? {
        guard !nonce.isEmpty, let der = pemBody(publicKeyPEM), let pkcs1 = rsaPublicKey(fromDER: der) else { return nil }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, nil) else { return nil }
        let n = [UInt8](nonce)
        let masked = Data((Array(password.utf8) + [0]).enumerated().map { $0.element ^ n[$0.offset % n.count] })
        return SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, masked as CFData, nil) as Data?
    }

    /// The decoded base64 body of a PEM block.
    private nonisolated static func pemBody(_ pem: String) -> Data? {
        guard pem.contains("-----BEGIN") else { return nil }
        let body = pem.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .joined()
        return body.isEmpty ? nil : Data(base64Encoded: body)
    }

    /// The PKCS#1 RSAPublicKey that Security wants, out of an X.509 SubjectPublicKeyInfo:
    /// SEQUENCE { SEQUENCE { OID, NULL }, BIT STRING { 0x00, RSAPublicKey } }. A key that is
    /// already PKCS#1 (SEQUENCE { INTEGER, INTEGER }) is returned as it is.
    private nonisolated static func rsaPublicKey(fromDER der: Data) -> Data? {
        var outer = DERReader(der)
        guard let body = outer.read(tag: 0x30) else { return nil }
        var inner = DERReader(body)
        if inner.peekTag == 0x02 { return der }
        guard inner.read(tag: 0x30) != nil, let bits = inner.read(tag: 0x03), bits.first == 0x00 else { return nil }
        return Data(bits.dropFirst())
    }

    // MARK: - COM_QUERY

    private func comQuery(_ conn: NWConnection, _ sql: String) async throws -> (columns: [String], rows: [[String?]]) {
        var payload = Data([0x03])                  // COM_QUERY
        payload.append(Data(sql.utf8))
        try await writePacket(conn, payload, seq: 0)

        let (first, _) = try await readPacket(conn)
        if first.first == 0xff { throw Self.parseError(first) }
        if first.first == 0x00 || first.first == 0xfe { return ([], []) }  // OK: no result set

        var r = ByteReader(first)
        let colCount = Int(r.lenEncInt() ?? 0)
        guard colCount > 0 else { return ([], []) }

        var columns: [String] = []
        columns.reserveCapacity(colCount)
        for _ in 0..<colCount {
            let (def, _) = try await readPacket(conn)
            columns.append(Self.columnName(def))
        }
        // EOF after column defs (server has no CLIENT_DEPRECATE_EOF since we didn't set it).
        // A server that skips it has sent the first row instead; keep that packet.
        let (afterCols, _) = try await readPacket(conn)
        var pending: Data? = (afterCols.first == 0xfe && afterCols.count < 9) ? nil : afterCols

        var rows: [[String?]] = []
        while true {
            let pkt: Data
            if let p = pending { pkt = p; pending = nil } else { (pkt, _) = try await readPacket(conn) }
            if pkt.first == 0xff { throw Self.parseError(pkt) }
            if (pkt.first == 0xfe && pkt.count < 9) { break }   // EOF → end of rows
            var rr = ByteReader(pkt)
            var row: [String?] = []
            row.reserveCapacity(colCount)
            for _ in 0..<colCount { row.append(rr.lenEncString()) }
            rows.append(row)
        }
        return (columns, rows)
    }

    // MARK: - Parsing helpers

    private static func columnName(_ def: Data) -> String {
        // Column definition 41: catalog, schema, table, org_table, name, org_name, …
        var r = ByteReader(def)
        _ = r.lenEncString()  // catalog
        _ = r.lenEncString()  // schema
        _ = r.lenEncString()  // table
        _ = r.lenEncString()  // org_table
        return r.lenEncString() ?? ""  // name
    }

    private static func parseError(_ pkt: Data) -> MySQLClientError {
        var r = ByteReader(pkt)
        _ = r.u8()                      // 0xff
        let code = Int(r.u16())
        // SQL state marker '#' + 5 chars (protocol 41), then message.
        var rest = r.remaining()
        if rest.first == 0x23 { rest = Array(rest.dropFirst(6)) }  // '#' + 5-char sqlstate
        let msg = String(decoding: rest, as: UTF8.self)
        return .server(code: code, message: msg.isEmpty ? "MySQL error \(code)" : msg)
    }
}

// MARK: - Capability flags

private let CLIENT_LONG_PASSWORD: UInt32    = 0x00000001
private let CLIENT_LONG_FLAG: UInt32        = 0x00000004
private let CLIENT_CONNECT_WITH_DB: UInt32  = 0x00000008
private let CLIENT_PROTOCOL_41: UInt32      = 0x00000200
private let CLIENT_TRANSACTIONS: UInt32     = 0x00002000
private let CLIENT_SECURE_CONNECTION: UInt32 = 0x00008000
private let CLIENT_PLUGIN_AUTH: UInt32      = 0x00080000

// MARK: - Little-endian append

private extension Data {
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xff)); append(UInt8((v >> 8) & 0xff))
        append(UInt8((v >> 16) & 0xff)); append(UInt8((v >> 24) & 0xff))
    }
}

// MARK: - Byte reader

/// Reads DER elements one after another: just enough to unwrap a public key.
nonisolated private struct DERReader {
    private let d: [UInt8]
    private var i = 0
    init(_ data: Data) { d = [UInt8](data) }
    var peekTag: UInt8? { i < d.count ? d[i] : nil }

    /// The contents of the next element when its tag is `tag`; nil otherwise or when malformed.
    mutating func read(tag: UInt8) -> Data? {
        guard i + 1 < d.count, d[i] == tag else { return nil }
        var j = i + 1
        var len = Int(d[j]); j += 1
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard (1...3).contains(n), j + n <= d.count else { return nil }
            len = d[j..<(j + n)].reduce(0) { ($0 << 8) | Int($1) }
            j += n
        }
        guard j + len <= d.count else { return nil }
        i = j + len
        return Data(d[j..<(j + len)])
    }
}

private struct ByteReader {
    private let d: [UInt8]
    private var i = 0
    init(_ data: Data) { d = [UInt8](data) }

    mutating func u8() -> UInt8 { guard i < d.count else { return 0 }; defer { i += 1 }; return d[i] }
    mutating func u16() -> UInt16 { UInt16(u8()) | (UInt16(u8()) << 8) }
    mutating func u32() -> UInt32 { UInt32(u16()) | (UInt32(u16()) << 16) }
    mutating func bytes(_ n: Int) -> [UInt8] {
        let end = min(i + n, d.count); defer { i = end }; return Array(d[i..<end])
    }
    mutating func cString() -> String {
        var out: [UInt8] = []
        while i < d.count, d[i] != 0 { out.append(d[i]); i += 1 }
        if i < d.count { i += 1 }  // skip null
        return String(decoding: out, as: UTF8.self)
    }
    mutating func remaining() -> [UInt8] { defer { i = d.count }; return Array(d[min(i, d.count)...]) }

    /// Length-encoded integer. nil for the 0xFB NULL marker.
    mutating func lenEncInt() -> UInt64? {
        let first = u8()
        switch first {
        case 0xfb: return nil
        case 0xfc: return UInt64(u16())
        case 0xfd: return UInt64(u8()) | (UInt64(u8()) << 8) | (UInt64(u8()) << 16)
        case 0xfe:
            var v: UInt64 = 0
            for s in stride(from: 0, through: 56, by: 8) { v |= UInt64(u8()) << s }
            return v
        default: return UInt64(first)
        }
    }

    /// Length-encoded string. nil for SQL NULL.
    mutating func lenEncString() -> String? {
        let mark = i < d.count ? d[i] : 0
        if mark == 0xfb { i += 1; return nil }
        guard let n = lenEncInt() else { return nil }
        let raw = bytes(Int(n))
        return String(decoding: raw, as: UTF8.self)
    }
}
