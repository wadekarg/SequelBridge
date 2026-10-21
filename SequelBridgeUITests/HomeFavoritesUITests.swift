//
//  HomeFavoritesUITests.swift
//  SequelBridgeUITests
//
//  Removing a favorite on Home asks first, since its saved password goes too: Cancel keeps
//  it, Remove takes it off the list. It went on one click before. Two SQLite files, so no
//  server is needed.
//

import XCTest

final class HomeFavoritesUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-fav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = dir.appendingPathComponent("connections.json")
        try """
        [
          {"id":"5B0A0000-0004-4000-8000-000000000001","name":"Lite A","alias":"litea","connectionType":"TCP/IP","color":"#3A9AA8",
           "host":"","port":0,"username":"","database":"\(dir.path)/a.sqlite","engine":"sqlite","folder":"","readOnly":false},
          {"id":"5B0A0000-0004-4000-8000-000000000002","name":"Lite B","alias":"liteb","connectionType":"TCP/IP","color":"#D97A0B",
           "host":"","port":0,"username":"","database":"\(dir.path)/b.sqlite","engine":"sqlite","folder":"","readOnly":false}
        ]
        """.write(to: fixture, atomically: true, encoding: .utf8)
        let support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-SBConnectionsFile", fixture.path, "-SBSupportDir", support.path,
                               "-ApplePersistenceIgnoreState", "YES", "-theme", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["home.select.liteb"].waitForExistence(timeout: 30), "Home didn't show the connections")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// A button of the question on screen, not the Touch Bar's copy.
    private func dialogButton(_ title: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for b in [app.sheets.buttons[title], app.dialogs.buttons[title], app.windows.buttons[title]] where b.exists { return b }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return nil
    }

    func testRemovingAFavoriteAsksFirst() throws {
        let row = app.staticTexts["Lite B"]
        row.rightClick()
        app.menuItems["Remove from Favorites…"].click()
        try XCTUnwrap(dialogButton("Cancel"), "removing a favorite didn't ask first").click()
        XCTAssertTrue(app.buttons["home.select.liteb"].exists, "Cancel removed the favorite")
        row.rightClick()
        app.menuItems["Remove from Favorites…"].click()
        try XCTUnwrap(dialogButton("Remove “Lite B”"), "no Remove in the question").click()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["home.select.liteb"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "the removed favorite is still listed")
        XCTAssertTrue(app.buttons["home.select.litea"].exists, "the other favorite went too")
    }
}
