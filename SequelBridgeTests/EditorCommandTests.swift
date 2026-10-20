//
//  EditorCommandTests.swift
//  SequelBridgeTests
//
//  ⌘/ ⌘] ⌘[ and ⌘F in the SQL editor itself: each edit reaches the Query tab's text the
//  way typing does (through the delegate), and the editor offers macOS's find bar.
//  From the Sequel Ace checklist (guide/SEQUEL-ACE.md), where they were missing.
//

import AppKit
import Testing
@testable import SequelBridge

@MainActor
@Suite("Editor: ⌘/ ⌘] ⌘[ and Find in the text view")
struct EditorCommandTests {

    private final class RecordingDelegate: NSObject, NSTextViewDelegate {
        var changes: [String] = []
        func textDidChange(_ notification: Notification) {
            changes.append((notification.object as? NSTextView)?.string ?? "")
        }
    }

    private func editor(_ text: String, caret: Int) -> (SQLTextView, RecordingDelegate) {
        let tv = SQLTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let delegate = RecordingDelegate()
        tv.string = text
        tv.delegate = delegate
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        return (tv, delegate)
    }

    @Test("⌘/ comments the caret's line, and the change reaches the Query tab's text")
    func comment() {
        let (tv, delegate) = editor("SELECT 1", caret: 0)
        tv.perform(.toggleComment)
        #expect(tv.string == "-- SELECT 1")
        #expect(tv.selectedRange() == NSRange(location: 3, length: 0))
        #expect(delegate.changes == ["-- SELECT 1"])
    }

    @Test("⌘] and ⌘[ indent and outdent by the editor's tab width")
    func indent() {
        let (tv, _) = editor("SELECT 1", caret: 0)
        tv.tabWidth = 2
        tv.perform(.indent)
        #expect(tv.string == "  SELECT 1")
        tv.perform(.outdent)
        #expect(tv.string == "SELECT 1")
    }

    @Test("the editor offers macOS's find bar, searching as you type")
    func findBar() {
        let (tv, _) = editor("SELECT 1", caret: 0)
        SQLTextView.configureForEditing(tv)
        #expect(tv.usesFindBar)
        #expect(tv.isIncrementalSearchingEnabled)
    }
}
