//
//  MySQLAuthTests.swift
//  SequelBridgeTests
//
//  The app's own MySQL client (EXPLAIN, SHOW CREATE TABLE) logs in by itself. MySQL 8
//  servers announce caching_sha2_password, which it didn't speak, so EXPLAIN failed and
//  table dumps lost their foreign keys there. These pin the pieces of that login that
//  need no server: both password scrambles against reference values (computed with
//  Python's hashlib), and the RSA exchange a first login over plain TCP needs.
//

import Foundation
import Security
import Testing
@testable import SequelBridge

@Suite("MySQL login: password scrambles and the RSA exchange")
struct MySQLAuthTests {
    private let nonce = Data(1...20)

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    @Test("mysql_native_password: SHA1(pwd) XOR SHA1(nonce + SHA1(SHA1(pwd)))")
    func native() {
        #expect(hex(MySQLClient.nativePasswordScramble(password: "sbverify123", scramble: nonce))
                == "ca806c61017f82fc11215e3d9ebbfd110434ac45")
        #expect(MySQLClient.nativePasswordScramble(password: "", scramble: nonce).isEmpty)
    }

    @Test("caching_sha2_password: SHA256(pwd) XOR SHA256(SHA256(SHA256(pwd)) + nonce)")
    func cachingSha2() {
        #expect(hex(MySQLClient.cachingSha2Scramble(password: "sbverify123", nonce: nonce))
                == "90da8d058d9cf6ee52381f29d1aae41013b8a9a6d211a0e0bf289df8abf93268")
        #expect(MySQLClient.cachingSha2Scramble(password: "", nonce: nonce).isEmpty)
    }

    /// A PEM "PUBLIC KEY" (X.509 SubjectPublicKeyInfo), the form MySQL sends.
    private func spkiPEM(_ key: SecKey) throws -> String {
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
        func len(_ n: Int) -> [UInt8] { n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xff)] }
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString: [UInt8] = [0x03] + len(pkcs1.count + 1) + [0x00] + [UInt8](pkcs1)
        let body = algorithm + bitString
        let der = Data([0x30] + len(body.count) + body)
        return "-----BEGIN PUBLIC KEY-----\n"
            + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            + "\n-----END PUBLIC KEY-----\n"
    }

    @Test("a first login over plain TCP sends the password RSA-encrypted with the server's key")
    func rsaExchange() throws {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let priv = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let pub = try #require(SecKeyCopyPublicKey(priv))
        let cipher = try #require(MySQLClient.rsaEncryptedPassword("sbverify123", nonce: nonce, publicKeyPEM: try spkiPEM(pub)))
        let plain = try #require(SecKeyCreateDecryptedData(priv, .rsaEncryptionOAEPSHA1, cipher as CFData, nil) as Data?)
        // The server XORs the plaintext with the nonce (repeated) and expects the password and a NUL.
        let unmasked = Data(plain.enumerated().map { $0.element ^ nonce[$0.offset % nonce.count] })
        #expect(unmasked == Data("sbverify123".utf8) + Data([0]))
    }

    @Test("a key that isn't a PEM public key gives no ciphertext")
    func badKey() {
        #expect(MySQLClient.rsaEncryptedPassword("x", nonce: nonce, publicKeyPEM: "not a key") == nil)
        #expect(MySQLClient.rsaEncryptedPassword("x", nonce: nonce,
                                                 publicKeyPEM: "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----") == nil)
    }

    @MainActor @Test("a refused connection fails at once instead of waiting forever")
    func refusedFailsFast() async throws {
        let c = MySQLClient(.init(host: "127.0.0.1", port: 1, user: "u", password: "p", database: "", useTLS: false))
        let outcome = try #require(await finishes(within: 10) { try await c.query("SELECT 1") },
                                   "the client was still waiting after 10 seconds")
        #expect(throws: (any Error).self) { try outcome.get() }
    }

    @MainActor @Test("SSL to a server that isn't there fails at once, saying it couldn't connect")
    func sslUnreachable() async throws {
        let c = MySQLClient(.init(host: "127.0.0.1", port: 1, user: "u", password: "p", database: "", useTLS: true))
        let outcome = try #require(await finishes(within: 5) { try await c.query("SELECT 1") },
                                   "the client was still waiting after 5 seconds")
        guard case .failure(let error) = outcome else { Issue.record("it connected"); return }
        #expect("\(error)".localizedCaseInsensitiveContains("connect"), "got: \(error)")
    }
}
