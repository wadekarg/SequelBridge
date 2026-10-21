//
//  UpdatesUITests.swift
//  SequelBridgeUITests
//
//  Where updates are reached: SequelBridge → Check for Updates…, and Settings → Updates
//  with its daily-check switch. A copy launched for the tests runs no updater (it would
//  fetch the feed and keep its state in the app's own settings), so both stay off here;
//  scripts/test-update-e2e.sh checks the updating itself.
//

import XCTest

final class UpdatesUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-upd-\(UUID().uuidString)")
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

    func testCheckForUpdatesIsInTheAppMenu() {
        let appMenu = app.menuBars.menuBarItems["SequelBridge"]
        appMenu.click()
        let item = app.menuItems["Check for Updates…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Check for Updates… in the SequelBridge menu")
        XCTAssertFalse(item.isEnabled, "a copy launched for the tests offered to check for updates")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSettingsHasAnUpdatesTab() {
        app.typeKey(",", modifierFlags: .command)
        let tab = app.windows.toolbars.buttons["Updates"].exists ? app.windows.toolbars.buttons["Updates"] : app.buttons["Updates"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Settings has no Updates tab")
        tab.click()
        // A switch in the grouped form, its title beside it rather than on it.
        let toggle = app.switches["settings.updates.auto"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the Updates tab has no daily-check switch")
        XCTAssertFalse(toggle.isEnabled, "a copy launched for the tests let its updater be switched on")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH %@", "SequelBridge ")).firstMatch.exists,
                      "the Updates tab doesn't say which version this is")
    }
}
