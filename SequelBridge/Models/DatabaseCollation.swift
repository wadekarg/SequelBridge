//
//  DatabaseCollation.swift
//  SequelBridge
//
//  A server's collations, for Add Database's Collation picker.
//

import Foundation

nonisolated struct DatabaseCollation: Equatable {
    let name: String
    let charset: String
    let isDefault: Bool

    /// The collations of `charset`, its default first, then by name.
    static func offered(_ all: [DatabaseCollation], charset: String) -> [String] {
        all.filter { $0.charset == charset }
            .sorted { ($0.isDefault ? 0 : 1, $0.name) < ($1.isDefault ? 0 : 1, $1.name) }
            .map(\.name)
    }
}
