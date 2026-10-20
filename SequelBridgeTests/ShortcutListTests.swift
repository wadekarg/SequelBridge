//
//  ShortcutListTests.swift
//  SequelBridgeTests
//
//  Settings' Shortcuts list and the guide's table promise the keys the app binds. Both
//  had drifted to six of them. These read the views' keyboard shortcuts and check each
//  is listed, in the app and in guide/FEATURES.md.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Shortcuts: what Settings and the guide list is what the app binds")
struct ShortcutListTests {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    /// Every key a SwiftUI button binds in the views, as ⌃⌥⇧⌘ plus the key.
    private func boundKeys() throws -> Set<String> {
        let views = repo.appendingPathComponent("SequelBridge/Views")
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        let pattern = try NSRegularExpression(
            pattern: #"\.keyboardShortcut\(\s*(?:"([^"]+)"|\.(return|escape))\s*,\s*modifiers:\s*(\[[^\]]*\]|\.\w+)\s*\)"#)
        var keys = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                func group(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
                let key = group(1).map { $0.uppercased() } ?? (group(2) == "return" ? "↵" : "Esc")
                let mods = group(3) ?? ""
                var symbol = ""
                if mods.contains("control") { symbol += "⌃" }
                if mods.contains("option") { symbol += "⌥" }
                if mods.contains("shift") { symbol += "⇧" }
                if mods.contains("command") { symbol += "⌘" }
                keys.insert(symbol + key)
            }
        }
        return keys
    }

    @Test("every key a button binds is in Settings' list")
    func settingsListsEveryBinding() throws {
        let bound = try boundKeys()
        #expect(bound.count >= 14, "the scan found only \(bound)")
        let listed = Set(Shortcuts.all.map(\.keys))
        #expect(bound.subtracting(listed).isEmpty, "bound but not listed: \(bound.subtracting(listed).sorted())")
    }

    @Test("the guide's table lists what Settings lists")
    func guideListsTheSame() throws {
        let guide = try String(contentsOf: repo.appendingPathComponent("guide/FEATURES.md"), encoding: .utf8)
        let missing = Shortcuts.all.filter { !guide.contains("| \($0.keys) |") }.map(\.keys)
        #expect(missing.isEmpty, "not in guide/FEATURES.md: \(missing)")
    }
}
