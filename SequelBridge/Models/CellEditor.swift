//
//  CellEditor.swift
//  SequelBridge
//
//  Editing a grid cell, kept free of views so the rules are testable. The Content tab
//  edits in the cell (InlineCellEdit); the Query tab opens the value in a popup
//  (CellEditorView) with Edit, then Save or Cancel (CellEditorState). CellEditability
//  says why a cell can't be edited.
//

import Foundation

struct CellEditorState {
    let column: String
    let columnType: String
    let originalValue: String          // "" when the cell is NULL
    let originalIsNull: Bool
    /// Why this cell can't be edited here, or nil when it can.
    let readOnlyReason: String?

    var isEditing = false
    var text: String
    var setNull: Bool

    init(column: String, columnType: String, value: String, isNull: Bool, readOnlyReason: String?) {
        self.column = column
        self.columnType = columnType
        self.originalValue = isNull ? "" : value
        self.originalIsNull = isNull
        self.readOnlyReason = readOnlyReason
        self.text = isNull ? "" : value
        self.setNull = isNull
    }

    var canEdit: Bool { readOnlyReason == nil }

    /// A change worth saving: NULL toggled, or new text while not NULL.
    var hasChanges: Bool {
        setNull != originalIsNull || (!setNull && text != originalValue)
    }

    var canSave: Bool { canEdit && isEditing && hasChanges }

    /// What Save writes: nil for SQL NULL. An empty string is a real value.
    var newValue: String? { setNull ? nil : text }
}

/// Why a cell in the Content tab can't be edited in place, or nil when it can.
nonisolated enum CellEditability {
    static func reason(engine: DatabaseEngine, readOnly: Bool, hasPrimaryKey: Bool) -> String? {
        if readOnly {
            return "This connection is read-only. Turn off read-only in the connection settings to edit."
        }
        if engine.isNative {
            return "ClickHouse rows are changed with ALTER TABLE … UPDATE in the Query tab, not edited in place."
        }
        if !hasPrimaryKey { return noPrimaryKey }
        return nil
    }

    static let noPrimaryKey = "This table has no primary key, so the app can't tell which row to update."
    /// A grid that shows no table's rows (the Server tab's lists).
    static let notEditable = "These values aren't a table's rows, so they can't be edited."
}

/// What ending an in-cell edit (the Content tab) does: Esc or no change leaves the
/// cell alone; anything else is saved. A NULL cell opens empty, so leaving it empty
/// keeps it NULL; clearing a value saves the empty string.
nonisolated enum InlineCellEdit {
    enum Outcome: Equatable { case unchanged, save(String) }

    static func outcome(original: String, originalIsNull: Bool, text: String, cancelled: Bool) -> Outcome {
        if cancelled { return .unchanged }
        if originalIsNull { return text.isEmpty ? .unchanged : .save(text) }
        return text == original ? .unchanged : .save(text)
    }
}
