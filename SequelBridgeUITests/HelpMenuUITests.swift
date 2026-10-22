//
//  HelpMenuUITests.swift
//  SequelBridgeUITests
//
//  The Help menu: the guide, how queries run, keyboard shortcuts, release notes, a way to
//  report an issue, the website and the source. Keyboard Shortcuts opens Settings on its
//  tab. The links open the browser, so they are listed here, not clicked; HelpLinksTests
//  checks where they point.
//

import XCTest

final class HelpMenuUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-help-\(UUID().uuidString)")
        let support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try "[]".write(to: support.appendingPathComponent("connections.json"), atomically: true, encoding: .utf8)
        app = XCUIApplication()
        app.launchArguments = ["-SBSupportDir", support.path, "-ApplePersistenceIgnoreState", "YES", "-theme", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["New Connection"].waitForExistence(timeout: 30), "Home didn't open")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func testHelpMenuListsTheGuideShortcutsReleaseNotesIssuesWebsiteAndSource() {
        app.menuBars.menuBarItems["Help"].click()
        for title in ["SequelBridge Help", "How Queries Run", "Keyboard Shortcuts", "Release Notes",
                      "Report an Issue…", "SequelBridge Website", "SequelBridge on GitHub"] {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 5), "no \(title) in the Help menu")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    func testKeyboardShortcutsOpensSettingsOnItsTab() {
        app.menuBars.menuBarItems["Help"].click()
        let item = app.menuItems["Keyboard Shortcuts"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Keyboard Shortcuts in the Help menu")
        item.click()
        // The Settings window is titled after the tab it shows.
        XCTAssertTrue(app.windows["Shortcuts"].waitForExistence(timeout: 10), "Settings didn't open on Shortcuts")
        XCTAssertTrue(app.staticTexts["Copy its name"].exists, "the Shortcuts tab's list isn't showing")
    }
}
