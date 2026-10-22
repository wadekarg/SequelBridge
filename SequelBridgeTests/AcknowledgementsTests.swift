//
//  AcknowledgementsTests.swift
//  SequelBridgeTests
//
//  The app ships code of others, built in: DuckDB, its MySQL, PostgreSQL and SQLite
//  drivers and their libraries (MariaDB Connector/C, libpq, OpenSSL, curl, zlib, lz4), and
//  Sparkle. Their licenses ask for their notices to go with the app: Help →
//  Acknowledgements shows Acknowledgements.txt (scripts/acknowledgements.py writes it).
//  MariaDB Connector/C is LGPL, linked statically: the page says how to relink it.
//

import AppKit
import SwiftUI
import Testing
@testable import SequelBridge

@Suite("Acknowledgements: the licenses of what the app ships")
struct AcknowledgementsTests {
    private func text() throws -> String {
        let url = try #require(Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"), "no Acknowledgements.txt in the app")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("every component the app ships is named, with its license")
    func everyComponent() throws {
        let t = try text()
        for name in ["DuckDB", "DuckDB MySQL extension", "DuckDB PostgreSQL extension", "DuckDB SQLite extension",
                     "duckdb-swift", "MariaDB Connector/C", "PostgreSQL (libpq)", "OpenSSL", "curl", "zlib", "LZ4",
                     "Sparkle"] {
            #expect(t.contains("\n== \(name)"), "no section for \(name)")
        }
        for license in ["MIT License", "GNU LESSER GENERAL PUBLIC LICENSE", "Apache License", "PostgreSQL License"] {
            #expect(t.contains(license), "no \(license)")
        }
    }

    @Test("MariaDB Connector/C, linked statically under the LGPL, says how to relink it")
    func relinking() throws {
        let t = try text()
        #expect(t.contains("scripts/build-duckdb.sh"))
        #expect(t.contains("https://github.com/wadekarg/SequelBridge"))
    }

    @MainActor
    @Test("the Acknowledgements window shows all of the file, to read and copy, not to edit")
    func window() throws {
        let host = NSHostingView(rootView: AcknowledgementsView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let textView = try #require(Self.textView(in: host), "no text in the window")
        #expect(textView.string == (try text()))
        #expect(textView.isSelectable && !textView.isEditable)
    }

    @MainActor
    private static func textView(in view: NSView) -> NSTextView? {
        if let t = view as? NSTextView { return t }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}
