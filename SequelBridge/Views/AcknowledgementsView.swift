//
//  AcknowledgementsView.swift
//  SequelBridge
//
//  Help → Acknowledgements: the projects whose code the app ships, with their licenses
//  (Acknowledgements.txt, which scripts/acknowledgements.py writes), to read, search and
//  copy from. An AppKit text view: the file is ~150 KB, more than a SwiftUI Text lays out
//  and selects smoothly.
//

import AppKit
import SwiftUI

struct AcknowledgementsView: NSViewRepresentable {
    static let windowID = "acknowledgements"

    static func text(in bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = Self.text()
        // After the text: the font applies to all of it. Monospaced, as the licenses are
        // laid out in their files.
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
