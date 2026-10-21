//
//  RowWrite.swift
//  SequelBridge
//
//  A row write the Content tab or an edited query result makes: one cell, a new row or
//  a deleted row, keyed by the row's primary key. The engine writes it in the SQL of
//  the route it takes (QueryEngine.writeRow).
//

import Foundation

nonisolated struct RowWrite: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        /// One cell; nil sets it to NULL.
        case set(column: String, value: String?)
        /// A new row: its filled-in fields. The text NULL means NULL, CURRENT_TIMESTAMP the time.
        case insert([String: String])
        case delete
    }

    /// One primary-key column and the row's value there; nil when the row has NULL.
    struct Key: Equatable, Sendable {
        let column: String
        let value: String?
    }

    let database: String
    let table: String
    let change: Change
    var key: [Key] = []
}
