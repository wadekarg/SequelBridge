//
//  WorkspaceControlsUITests.swift
//  SequelBridgeUITests
//
//  Clicks the workspace's tab strips and + buttons the way a person does. A tester on
//  an Apple Silicon Mac reported that the left panel's connection tabs, its + buttons
//  and the new-query + did nothing. These run on GitHub's macOS 15 and 26 machines
//  (.github/workflows/test.yml). They take over the screen while they run, so the local
//  test script leaves them out.
//
//  Two SQLite files in a temporary folder stand in for servers: no Docker, no network,
//  no password, and nothing in a folder macOS asks permission for.
//

import XCTest

final class WorkspaceControlsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeSQLite("a.sqlite", table: "alpha_items")
        try makeSQLite("b.sqlite", table: "beta_items")

        let fixture = dir.appendingPathComponent("connections.json")
        try """
        [
          {"id":"5B0A0000-0001-4000-8000-000000000001","name":"Lite A","alias":"litea","connectionType":"TCP/IP","color":"#3A9AA8",
           "host":"","port":0,"username":"","database":"\(dir.path)/a.sqlite","engine":"sqlite","folder":"","readOnly":false},
          {"id":"5B0A0000-0002-4000-8000-000000000002","name":"Lite B","alias":"liteb","connectionType":"TCP/IP","color":"#D97A0B",
           "host":"","port":0,"username":"","database":"\(dir.path)/b.sqlite","engine":"sqlite","folder":"","readOnly":false}
        ]
        """.write(to: fixture, atomically: true, encoding: .utf8)
        let support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchArguments = ["-SBConnectionsFile", fixture.path, "-SBSupportDir", support.path,
                               "-ApplePersistenceIgnoreState", "YES", "-theme", "Light"]
        app.launch()

        // Home: tick both connections, Connect.
        XCTAssertTrue(app.buttons["home.select.litea"].waitForExistence(timeout: 30), "Home didn't show the connections")
        app.buttons["home.select.litea"].click()
        app.buttons["home.select.liteb"].click()
        app.buttons["home.connect"].click()
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 120), "the workspace didn't open")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeSQLite(_ name: String, table: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [dir.appendingPathComponent(name).path,
                       "CREATE TABLE \(table) (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO \(table) VALUES (1, '\(table)-row');"]
        try p.run()
        p.waitUntilExit()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testNewQueryTabButtonOpensATab() {
        let tabs = app.descendants(matching: .any).matching(identifier: "query.tab")
        let before = tabs.count
        app.buttons["query.newTab"].click()
        XCTAssertEqual(tabs.count, before + 1, "the + didn't open a new query tab")
    }

    func testClickingAQueryTabSelectsIt() {
        // Two tabs, the second active; a click anywhere on the first selects it again.
        app.buttons["query.newTab"].click()
        let tabs = app.descendants(matching: .any).matching(identifier: "query.tab")
        XCTAssertEqual(tabs.count, 2)
        XCTAssertTrue(app.staticTexts["Query 2"].exists)
        let first = tabs.element(boundBy: 0)
        XCTAssertFalse(first.isSelected)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).click()   // the padding, left of the title
        XCTAssertTrue(first.isSelected, "clicking the first tab didn't select it")
    }

    func testCommandWClosesTheActiveQueryTab() {
        // Every tab's close button had ⌘W, so ⌘W closed whichever one SwiftUI found first.
        app.buttons["query.newTab"].click()
        app.buttons["query.newTab"].click()
        let tabs = app.descendants(matching: .any).matching(identifier: "query.tab")
        XCTAssertEqual(tabs.count, 3)
        tabs.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).click()
        XCTAssertTrue(tabs.element(boundBy: 1).isSelected, "the middle tab didn't take the click")
        app.typeKey("w", modifierFlags: .command)
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["Query 2"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "⌘W didn't close the active tab")
        XCTAssertTrue(app.staticTexts["Query 1"].exists, "⌘W closed another tab")
        XCTAssertTrue(app.staticTexts["Query 3"].exists, "⌘W closed another tab")
    }

    func testConnectionTabsSwitchTheSidebar() {
        element("sidebar.connection.liteb").click()
        XCTAssertTrue(app.staticTexts["beta_items"].waitForExistence(timeout: 15), "the liteb tab didn't show its tables")
        element("sidebar.connection.litea").click()
        XCTAssertTrue(app.staticTexts["alpha_items"].waitForExistence(timeout: 15), "the litea tab didn't show its tables")
    }

    func testAStatementThatNamesNoServerRunsOnTheActiveTab() {
        // Two servers open, the second tab picked: a table name with no server prefix is
        // that server's. It used to be refused ("Prefix each table with its server alias").
        element("sidebar.connection.liteb").click()
        let editor = element("query.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no SQL editor")
        editor.click()
        editor.typeText("SELECT name FROM beta_items")
        app.buttons["query.run"].click()
        XCTAssertTrue(app.staticTexts["beta_items-row"].waitForExistence(timeout: 30),
                      "the statement didn't run on liteb")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'Prefix each table'")).firstMatch.exists)
    }

    func testAddConnectionButtonOpensItsSheet() {
        app.buttons["sidebar.addConnection"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "the + didn't open the Add Connection sheet")
    }

    func testCreateTableButtonOpensItsSheet() {
        app.buttons["sidebar.createTable"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "the + didn't open the Create Table sheet")
    }
}
