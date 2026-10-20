//
//  SQLEditorView.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import SwiftUI
import AppKit

struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedSQL: String   // "" when nothing selected; set by selection changes
    @Binding var cursorLocation: Int   // the caret, in UTF-16 offsets: Run Current runs the statement there
    var fontSize: CGFloat = 13
    var tabWidth: Int = 4
    var onRun: () -> Void
    var completionItems: [String] = []

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SQLTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("query.editor")
        SQLTextView.configureForEditing(textView)
        (textView as? SQLTextView)?.tabWidth = tabWidth
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = Theme.monoNSFont(fontSize)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 8)

        // Line-number gutter on the left, like Sequel Ace.
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.hasHorizontalRuler = false
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        (textView as? SQLTextView)?.tabWidth = tabWidth
        if textView.string != text {
            textView.string = text
            highlight(textView: textView)
        }
        textView.font = Theme.monoNSFont(fontSize)
        context.coordinator.ruler?.refresh()
        context.coordinator.parent = self
    }

    // MARK: - Syntax highlighting

    func highlight(textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        for span in SQLHighlighter.spans(in: storage.string) {
            let color: NSColor
            switch span.kind {
            case .keyword: color = .systemPurple
            case .string:  color = .systemGreen
            case .comment: color = .systemGray
            }
            storage.addAttribute(.foregroundColor, value: color, range: span.range)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?

        init(_ parent: SQLEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.highlight(textView: tv)
            ruler?.refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let range = tv.selectedRange()
            parent.cursorLocation = range.location
            if range.length > 0, let r = Range(range, in: tv.string) {
                parent.selectedSQL = String(tv.string[r])
            } else {
                parent.selectedSQL = ""
            }
        }

        // Intercept Tab → trigger completion; let Cmd+Enter run query
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.complete(nil)
                return true
            }
            return false
        }

        // Provide keyword + table/column suggestions
        func textView(_ textView: NSTextView,
                      completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard charRange.length > 0,
                  let range = Range(charRange, in: textView.string) else { return [] }
            let partial = String(textView.string[range]).lowercased()
            guard !partial.isEmpty else { return [] }

            index?.pointee = 0
            return SQLCompletion.candidates(for: partial, items: parent.completionItems)
        }
    }
}

// MARK: - Line-number gutter

/// A left-hand gutter that numbers each logical line of the editor, aligned to the
/// text layout (wrapped continuation lines are left blank, like Sequel Ace / Xcode).
final class LineNumberRulerView: NSRulerView {

    private weak var textView: NSTextView?

    private var numberFont: NSFont = Theme.monoNSFont(11)
    private var textColor: NSColor { .tertiaryLabelColor }
    private var gutterColor: NSColor { NSColor.textBackgroundColor.blended(withFraction: 0.04, of: .labelColor) ?? .textBackgroundColor }
    private var dividerColor: NSColor { NSColor.separatorColor }

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.textView = textView
        self.clientView = textView
        self.ruleThickness = 34

        // Redraw as the text scrolls.
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func boundsChanged() { needsDisplay = true }

    /// Re-measure the width for the current line count and repaint. Call on text/font change.
    func refresh() {
        numberFont = Theme.monoNSFont(max(9, (textView?.font?.pointSize ?? 13) - 2))
        updateThickness()
        needsDisplay = true
    }

    private func updateThickness() {
        let lines = (textView?.string).map { lineCount(of: $0 as NSString) } ?? 1
        let digits = max(2, String(max(1, lines)).count)
        let sample = String(repeating: "9", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: [.font: numberFont]).width) + 12
        if abs(width - ruleThickness) > 0.5 { ruleThickness = width }
    }

    private func lineCount(of s: NSString) -> Int {
        guard s.length > 0 else { return 1 }
        var count = 1
        for i in 0..<s.length where s.character(at: i) == 10 { count += 1 }
        return count
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager else { return }

        // Gutter background + right divider.
        gutterColor.setFill()
        bounds.fill()
        dividerColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        divider.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        divider.lineWidth = 1
        divider.stroke()

        let content = textView.string as NSString
        let yInset = textView.textContainerInset.height
        let visibleRect = textView.visibleRect
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: textColor]

        func draw(_ number: Int, atFragmentY fragY: CGFloat, height: CGFloat) {
            let y = fragY + yInset - visibleRect.minY
            guard y + height >= 0, y <= bounds.height else { return }
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 5,
                                   y: y + (height - size.height) / 2),
                       withAttributes: attrs)
        }

        var lineNumber = 1
        var charIndex = 0
        let length = content.length
        while charIndex < length {
            let lineRange = content.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var effective = NSRange()
            let fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: &effective)
            draw(lineNumber, atFragmentY: fragRect.minY, height: fragRect.height)
            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }
        // Empty document, or a trailing newline → one more (empty) line to number.
        if length == 0 || content.character(at: length - 1) == 10 {
            let extra = layoutManager.extraLineFragmentRect
            let height = extra.height > 0 ? extra.height : numberFont.boundingRectForFont.height + 4
            draw(lineNumber, atFragmentY: extra.minY, height: height)
        }
    }
}

// MARK: - SQL keywords for completion

nonisolated enum SQLKeywords {
    static let all: [String] = [
        "SELECT","FROM","WHERE","JOIN","LEFT","RIGHT","INNER","OUTER","CROSS",
        "ON","AND","OR","NOT","IN","LIKE","AS","GROUP","BY","ORDER","HAVING",
        "LIMIT","OFFSET","INSERT","INTO","VALUES","UPDATE","SET","DELETE",
        "CREATE","ALTER","DROP","TABLE","INDEX","VIEW","DATABASE","SCHEMA",
        "DISTINCT","UNION","ALL","CASE","WHEN","THEN","ELSE","END",
        "IS","NULL","BETWEEN","EXISTS","WITH","COUNT","SUM","AVG","MIN","MAX",
        "COALESCE","IFNULL","IF","NOW","CURDATE","DATE","YEAR","MONTH","DAY",
        "CONCAT","SUBSTRING","TRIM","UPPER","LOWER","LENGTH","REPLACE",
        "PRIMARY","KEY","FOREIGN","REFERENCES","UNIQUE","DEFAULT","NOT NULL",
        "AUTO_INCREMENT","ENGINE","CHARSET","COLLATE","COMMENT",
        "SHOW","TABLES","DATABASES","COLUMNS","STATUS","DESCRIBE","EXPLAIN",
        "BEGIN","COMMIT","ROLLBACK","TRANSACTION","TRUNCATE","RENAME","TO",
        "TRUE","FALSE","CURRENT_TIMESTAMP","INT","VARCHAR","TEXT","DATETIME",
        "FLOAT","DOUBLE","DECIMAL","BOOLEAN","BLOB","JSON","ENUM","BIGINT",
    ]
}

// MARK: - Text view

/// The editor's text view. Assistive technology sets a field's content through
/// `setAccessibilityValue`, which NSTextView applies without telling its delegate —
/// the SwiftUI binding never saw the query, the next update reverted the text, and
/// Run saw an empty statement. Route it through the normal editing path so the
/// delegate, and with it the binding, hears about it exactly as for typed text.
final class SQLTextView: NSTextView {
    enum Command { case toggleComment, indent, outdent }

    /// Spaces ⌘] adds and ⌘[ takes off.
    var tabWidth = 4

    /// ⌘/ comments or uncomments the selected lines; ⌘] and ⌘[ indent and outdent them.
    /// The edit is one undo step and reaches the delegate like typed text.
    func perform(_ command: Command) {
        let selection = selectedRange()
        let edit: EditorEdits.Edit
        switch command {
        case .toggleComment: edit = EditorEdits.toggleComment(string, selection: selection)
        case .indent:        edit = EditorEdits.shift(string, selection: selection, right: true, width: tabWidth)
        case .outdent:       edit = EditorEdits.shift(string, selection: selection, right: false, width: tabWidth)
        }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        guard edit.text != string, shouldChangeText(in: whole, replacementString: edit.text) else { return }
        replaceCharacters(in: whole, with: edit.text)
        didChangeText()
        setSelectedRange(edit.selection)
    }

    /// macOS's find bar (⌘F, ⌘G), searching as you type.
    static func configureForEditing(_ textView: NSTextView) {
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "/": perform(.toggleComment); return true
        case "]": perform(.indent); return true
        case "[": perform(.outdent); return true
        case "f": find(.showFindInterface); return true
        case "g": find(.nextMatch); return true
        default:  return super.performKeyEquivalent(with: event)
        }
    }

    private func find(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performFindPanelAction(sender)
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard let newText = value as? String else { return }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: whole, replacementString: newText) else { return }
        replaceCharacters(in: whole, with: newText)
        didChangeText()
    }
}
