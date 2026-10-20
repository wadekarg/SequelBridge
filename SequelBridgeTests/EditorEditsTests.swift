//
//  EditorEditsTests.swift
//  SequelBridgeTests
//
//  The editor's ⌘/ (comment or uncomment the selected lines) and ⌘] / ⌘[ (indent, outdent),
//  as in Sequel Ace: from the Sequel Ace checklist (guide/SEQUEL-ACE.md), where they were
//  missing. A selection that ends at the start of a line leaves that line alone.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Editor: comment and indent lines")
struct EditorEditsTests {
    private func r(_ location: Int, _ length: Int = 0) -> NSRange { NSRange(location: location, length: length) }

    @Test("⌘/ comments the caret's line, and uncomments a commented one")
    func commentCaret() {
        #expect(EditorEdits.toggleComment("SELECT 1", selection: r(0)) == .init(text: "-- SELECT 1", selection: r(3)))
        #expect(EditorEdits.toggleComment("-- SELECT 1", selection: r(5)) == .init(text: "SELECT 1", selection: r(2)))
        #expect(EditorEdits.toggleComment("--SELECT 1", selection: r(4)) == .init(text: "SELECT 1", selection: r(2)))
    }

    @Test("⌘/ on several lines: comments them all unless every one is commented; blank lines stay blank")
    func commentLines() {
        #expect(EditorEdits.toggleComment("SELECT 1\nFROM t\n", selection: r(0, 15))
                == .init(text: "-- SELECT 1\n-- FROM t\n", selection: r(0, 21)))
        #expect(EditorEdits.toggleComment("-- a\n-- b", selection: r(0, 9)) == .init(text: "a\nb", selection: r(0, 3)))
        #expect(EditorEdits.toggleComment("-- a\nb", selection: r(0, 6)).text == "-- -- a\n-- b")
        #expect(EditorEdits.toggleComment("a\n\nb", selection: r(0, 4)).text == "-- a\n\n-- b")
        #expect(EditorEdits.toggleComment("a\nb\nc", selection: r(0, 2)).text == "-- a\nb\nc")
    }

    @Test("⌘] indents and ⌘[ outdents the selected lines by the tab width")
    func shift() {
        #expect(EditorEdits.shift("SELECT 1", selection: r(0), right: true, width: 4) == .init(text: "    SELECT 1", selection: r(4)))
        #expect(EditorEdits.shift("    SELECT 1", selection: r(6), right: false, width: 4) == .init(text: "SELECT 1", selection: r(2)))
        #expect(EditorEdits.shift("  a", selection: r(3), right: false, width: 4) == .init(text: "a", selection: r(1)))
        #expect(EditorEdits.shift("a\nb", selection: r(0, 3), right: true, width: 4) == .init(text: "    a\n    b", selection: r(0, 11)))
        #expect(EditorEdits.shift("a", selection: r(1), right: false, width: 4) == .init(text: "a", selection: r(1)))
    }
}
