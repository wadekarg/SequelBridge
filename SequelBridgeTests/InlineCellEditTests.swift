//
//  InlineCellEditTests.swift
//  SequelBridgeTests
//
//  The Content tab edits a cell in place, like Sequel Ace: double-click, type, Return
//  or a click elsewhere saves, Esc cancels. The bug this pins: a double-clicked row is
//  selected, and a selected row's cells draw white text; the edit kept that white on
//  the editor's light background, so typed text was invisible.
//

import AppKit
import Testing
@testable import SequelBridge

@Suite("In-cell editing")
struct InlineCellEditTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    @Test("what ending an in-cell edit does")
    func outcome() {
        #expect(InlineCellEdit.outcome(original: "paid", originalIsNull: false, text: "paid", cancelled: false) == .unchanged)
        #expect(InlineCellEdit.outcome(original: "paid", originalIsNull: false, text: "shipped", cancelled: false) == .save("shipped"))
        #expect(InlineCellEdit.outcome(original: "paid", originalIsNull: false, text: "shipped", cancelled: true) == .unchanged)
        #expect(InlineCellEdit.outcome(original: "paid", originalIsNull: false, text: "", cancelled: false) == .save(""))
        #expect(InlineCellEdit.outcome(original: "", originalIsNull: true, text: "", cancelled: false) == .unchanged)
        #expect(InlineCellEdit.outcome(original: "", originalIsNull: true, text: "x", cancelled: false) == .save("x"))
    }

    @MainActor @Test("the text being edited is readable on a selected row")
    func readableOnSelectedRow() {
        let cell = DataCellView.make()
        cell.configure(value: "paid", isNull: false, numeric: false, font: font)
        cell.backgroundStyle = .emphasized                    // a selected row: white text on blue
        #expect(cell.textField?.textColor == .white)
        cell.beginInlineEdit(text: "paid", placeholder: nil, font: font)
        #expect(cell.textField?.textColor == .textColor)
        #expect(cell.textField?.drawsBackground == true)
        #expect(cell.textField?.backgroundColor == .textBackgroundColor)
        #expect(cell.textField?.isEditable == true)
        cell.backgroundStyle = .emphasized                    // the table redraws the selection mid-edit
        #expect(cell.textField?.textColor == .textColor)
        cell.endInlineEdit()
        #expect(cell.textField?.isEditable == false)
        #expect(cell.textField?.drawsBackground == false)
        #expect(cell.textField?.textColor == .white)          // back to the selected row's look
    }

    @MainActor @Test("a NULL cell opens empty, with NULL as the placeholder, in the regular font")
    func nullCell() {
        let cell = DataCellView.make()
        cell.configure(value: "NULL", isNull: true, numeric: false, font: font)
        cell.beginInlineEdit(text: "", placeholder: "NULL", font: font)
        #expect(cell.textField?.stringValue == "")
        #expect(cell.textField?.placeholderString == "NULL")
        #expect(cell.textField?.font == font)
        #expect(cell.textField?.textColor == .textColor)
    }

    @MainActor @Test("a NULL cell keeps its font, in italics, and a reused cell gets the regular one back")
    func nullFont() throws {
        // On macOS 15 this crashed: the cell read its font back from the text field and got nil.
        let cell = DataCellView.make()
        cell.configure(value: "NULL", isNull: true, numeric: false, font: font)
        let italic = try #require(cell.textField?.font)
        #expect(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        cell.configure(value: "paid", isNull: false, numeric: false, font: font)
        #expect(cell.textField?.font == font)
    }
}
