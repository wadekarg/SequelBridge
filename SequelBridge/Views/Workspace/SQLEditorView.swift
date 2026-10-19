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
    var fontSize: CGFloat = 13
    var onRun: () -> Void
    var completionItems: [String] = []

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SQLTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("query.editor")
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

        let keywords = ["SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER",
                        "OUTER", "ON", "AND", "OR", "NOT", "IN", "LIKE", "AS",
                        "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET",
                        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
                        "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW",
                        "DISTINCT", "UNION", "ALL", "CASE", "WHEN", "THEN", "ELSE",
                        "END", "IS", "NULL", "BETWEEN", "EXISTS", "WITH"]

        let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let str = storage.string
            for match in regex.matches(in: str, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: match.range)
            }
        }

        // String literals
        if let regex = try? NSRegularExpression(pattern: "'[^']*'") {
            let str = storage.string
            for match in regex.matches(in: str, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: match.range)
            }
        }

        // Line comments
        if let regex = try? NSRegularExpression(pattern: "--[^\\n]*") {
            let str = storage.string
            for match in regex.matches(in: str, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: NSColor.systemGray, range: match.range)
            }
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

            var candidates = SQLKeywords.all + parent.completionItems
            candidates = Array(Set(candidates))  // deduplicate
            index?.pointee = 0
            return candidates
                .filter { $0.lowercased().hasPrefix(partial) }
                .sorted { $0.lowercased() < $1.lowercased() }
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

enum SQLKeywords {
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
    override func setAccessibilityValue(_ value: Any?) {
        guard let newText = value as? String else { return }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: whole, replacementString: newText) else { return }
        replaceCharacters(in: whole, with: newText)
        didChangeText()
    }
}
