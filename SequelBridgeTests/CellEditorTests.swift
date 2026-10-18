//
//  CellEditorTests.swift
//  SequelBridgeTests
//
//  The popup a double-click opens on a grid cell: what it offers, when Save can run,
//  and what Save writes. Hermetic.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Cell editor popup")
struct CellEditorTests {

    @Test("a cell opens for viewing; Save needs Edit and a change")
    func saveNeedsAChange() {
        var s = CellEditorState(column: "status", columnType: "VARCHAR", value: "paid", isNull: false, readOnlyReason: nil)
        #expect(s.canEdit && !s.isEditing && !s.canSave)
        s.isEditing = true
        #expect(!s.canSave)                      // nothing changed yet
        s.text = "shipped"
        #expect(s.canSave && s.newValue == "shipped")
        s.text = "paid"
        #expect(!s.canSave)                      // back to the original
    }

    @Test("NULL is a change of its own, and Save writes NULL")
    func nullToggle() {
        var s = CellEditorState(column: "note", columnType: "VARCHAR", value: "x", isNull: false, readOnlyReason: nil)
        s.isEditing = true
        s.setNull = true
        #expect(s.canSave && s.newValue == nil)
        var n = CellEditorState(column: "note", columnType: "VARCHAR", value: "", isNull: true, readOnlyReason: nil)
        n.isEditing = true
        #expect(n.setNull && !n.canSave)         // a NULL cell starts as NULL
        n.setNull = false
        #expect(n.canSave && n.newValue == "")   // the empty string is a real value
    }

    @Test("a cell that can't be edited says why and never saves")
    func readOnly() {
        var s = CellEditorState(column: "id", columnType: "INT", value: "1", isNull: false,
                                readOnlyReason: "This connection is read-only.")
        #expect(!s.canEdit)
        s.isEditing = true
        s.text = "2"
        #expect(!s.canSave)
    }

    @Test("why a Content cell can't be edited: read-only, ClickHouse, no primary key")
    func reasons() {
        #expect(CellEditability.reason(engine: .mysql, readOnly: false, hasPrimaryKey: true) == nil)
        #expect(CellEditability.reason(engine: .postgres, readOnly: false, hasPrimaryKey: true) == nil)
        #expect(CellEditability.reason(engine: .sqlite, readOnly: false, hasPrimaryKey: true) == nil)
        #expect(CellEditability.reason(engine: .mysql, readOnly: true, hasPrimaryKey: true)?.contains("read-only") == true)
        #expect(CellEditability.reason(engine: .clickhouse, readOnly: false, hasPrimaryKey: true)?.contains("ClickHouse") == true)
        #expect(CellEditability.reason(engine: .mysql, readOnly: false, hasPrimaryKey: false)?.contains("primary key") == true)
    }
}
