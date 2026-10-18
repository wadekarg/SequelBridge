//
//  SQLTextViewAccessibilityTests.swift
//  SequelBridgeTests
//
//  Assistive technology (and any accessibility client) sets a text field's content
//  through `setAccessibilityValue`. NSTextView applies that without telling its
//  delegate, so the SQL editor's SwiftUI binding never saw the new query: the next
//  view update reverted the text, and Run saw an empty statement. SQLTextView routes
//  an accessibility value change through the normal editing path, so the delegate —
//  and with it the binding — is told exactly as for typed text.
//

import AppKit
import Testing
@testable import SequelBridge

@MainActor
@Suite("SQL editor accessibility")
struct SQLTextViewAccessibilityTests {

    private final class RecordingDelegate: NSObject, NSTextViewDelegate {
        var changes: [String] = []
        func textDidChange(_ notification: Notification) {
            changes.append((notification.object as? NSTextView)?.string ?? "")
        }
    }

    @Test("an accessibility value change reaches the delegate like typed text")
    func accessibilitySetValueNotifiesDelegate() {
        let textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let delegate = RecordingDelegate()
        textView.delegate = delegate
        textView.string = "SELECT 1"

        textView.setAccessibilityValue("SELECT 2 AS two")

        #expect(textView.string == "SELECT 2 AS two")
        #expect(delegate.changes == ["SELECT 2 AS two"])
    }

    @Test("a non-string accessibility value is ignored safely")
    func ignoresNonString() {
        let textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let delegate = RecordingDelegate()
        textView.delegate = delegate
        textView.string = "SELECT 1"

        textView.setAccessibilityValue(42)

        #expect(textView.string == "SELECT 1")
        #expect(delegate.changes.isEmpty)
    }
}
