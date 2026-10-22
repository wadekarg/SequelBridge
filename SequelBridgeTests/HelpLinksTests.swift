//
//  HelpLinksTests.swift
//  SequelBridgeTests
//
//  Where the Help menu and the About window point: the guide's pages on GitHub (which
//  must exist in the repo, or the menu would open a missing page), the releases, the
//  issue form, the website and the source.
//

import AppKit
import Foundation
import Testing
@testable import SequelBridge

@Suite("Help menu and About window: where they point")
struct HelpLinksTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test("each link is the project's own page, over https")
    func links() {
        #expect(HelpLinks.github.absoluteString == "https://github.com/wadekarg/SequelBridge")
        #expect(HelpLinks.guide.absoluteString == "https://github.com/wadekarg/SequelBridge/blob/main/guide/FEATURES.md")
        #expect(HelpLinks.querying.absoluteString == "https://github.com/wadekarg/SequelBridge/blob/main/guide/QUERYING.md")
        #expect(HelpLinks.releaseNotes.absoluteString == "https://github.com/wadekarg/SequelBridge/releases")
        #expect(HelpLinks.reportIssue.absoluteString == "https://github.com/wadekarg/SequelBridge/issues/new/choose")
        #expect(HelpLinks.website.absoluteString == "https://sequelbridge.pages.dev")
    }

    @Test("the guide pages it opens are in the repo: a rename would break the menu")
    func guidePagesExist() {
        for url in [HelpLinks.guide, HelpLinks.querying] {
            let path = url.absoluteString.replacingOccurrences(of: HelpLinks.github.absoluteString + "/blob/main/", with: "")
            #expect(FileManager.default.fileExists(atPath: Self.repoRoot.appendingPathComponent(path).path), "\(path)")
        }
    }

    @Test("the About window's credits link the website and GitHub")
    func aboutCredits() throws {
        let url = try #require(Bundle.main.url(forResource: "Credits", withExtension: "rtf"), "no Credits.rtf in the app")
        let credits = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        var links: [String] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let link = value as? URL { links.append(link.absoluteString) } else if let link = value as? String { links.append(link) }
        }
        #expect(Set(links) == [HelpLinks.website.absoluteString, HelpLinks.github.absoluteString])
        #expect(credits.string.contains("Website") && credits.string.contains("GitHub"))
        // No color of its own: the About window's text color, readable in Dark Mode too.
        var colored = false
        credits.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if value != nil { colored = true }
        }
        #expect(!colored, "the credits set a text color")
    }
}
