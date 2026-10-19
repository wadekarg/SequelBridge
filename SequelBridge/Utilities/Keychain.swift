//
//  Keychain.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import Foundation
import Security

enum Keychain {
    /// The item for a connection's database password, or, with `kind`, for another of
    /// its secrets ("ssh-password", "ssh-passphrase").
    private static func key(for id: UUID, kind: String? = nil) -> String {
        kind.map { "SequelBridge-\(id.uuidString)-\($0)" } ?? "SequelBridge-\(id.uuidString)"
    }

    @discardableResult
    static func save(_ password: String, for id: UUID, kind: String? = nil) -> Bool {
        let data = Data(password.utf8)
        let k = key(for: id, kind: kind)
        let searchQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrAccount as String:  k,
            kSecAttrService as String:  "SequelBridge"
        ]
        // Fast path: update the existing item in place (keeps its ACL).
        let updateStatus = SecItemUpdate(
            searchQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }

        // The update didn't take. That happens when there's no item yet
        // (errSecItemNotFound) OR when an item exists that this process can't update —
        // e.g. it was created by a differently-signed build of the app, so its keychain
        // ACL rejects the in-place write. In the latter case a plain SecItemAdd fails with
        // errSecDuplicateItem and the password silently never persists (the original bug).
        // Delete any existing item first, then add a fresh one this build owns.
        var addQuery = searchQuery
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        if addStatus == errSecDuplicateItem {
            SecItemDelete(searchQuery as CFDictionary)
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func load(for id: UUID, kind: String? = nil) -> String? {
        let k = key(for: id, kind: kind)
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      k,
            kSecAttrService as String:      "SequelBridge",
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for id: UUID, kind: String? = nil) {
        let k = key(for: id, kind: kind)
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrAccount as String:  k,
            kSecAttrService as String:  "SequelBridge"
        ]
        SecItemDelete(query as CFDictionary)
    }
}