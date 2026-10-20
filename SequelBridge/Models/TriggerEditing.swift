//
//  TriggerEditing.swift
//  SequelBridge
//
//  Where the Triggers tab can add and drop a trigger. A PostgreSQL trigger runs a trigger
//  function that has to exist first, so adding one there is typed in the Query tab.
//

import Foundation

nonisolated enum TriggerEditing {
    static func canCreate(on engine: DatabaseEngine) -> Bool { engine == .mysql || engine == .sqlite }
    static func canDrop(on engine: DatabaseEngine) -> Bool { engine != .clickhouse }

    /// Why a trigger can't be added (or dropped) here, if it can't.
    static func reason(_ engine: DatabaseEngine) -> String? {
        switch engine {
        case .mysql, .sqlite: return nil
        case .postgres:       return "A PostgreSQL trigger runs a trigger function, which has to exist first: write CREATE FUNCTION and CREATE TRIGGER in the Query tab."
        case .clickhouse:     return "ClickHouse has no triggers."
        }
    }
}
