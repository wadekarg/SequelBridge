//
//  MySQLRefreshUITests.swift
//  SequelBridgeUITests
//
//  Refresh (⇧⌘R) shows what changed outside the app. Two connections to the same
//  MariaDB: a table made through one is unknown to the other until its Refresh. The
//  app's own DDL refreshes only the connection it ran on. Skipped without SB_UI_MYSQL_PORT.
//

import XCTest

final class MySQLRefreshUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let port = env["SB_UI_MYSQL_PORT"] else { throw XCTSkip("no MariaDB for the UI tests (SB_UI_MYSQL_PORT)") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func entry(_ n: Int, _ alias: String) -> [String: Any] {
            ["id": "5B0A0000-0000-4000-8000-00000000020\(n)", "name": alias, "alias": alias,
             "connectionType": "TCP/IP", "color": "#3A9AA8",
             "host": env["SB_UI_MYSQL_HOST"] ?? "127.0.0.1", "port": Int(port) ?? 3306,
             "username": env["SB_UI_MYSQL_USER"] ?? "sbui", "password": env["SB_UI_MYSQL_PASS"] ?? "",
             "database": "sbwrite", "engine": "mysql", "folder": "", "readOnly": false]
        }
        let fixture = dir.appendingPathComponent("connections.json")
        try JSONSerialization.data(withJSONObject: [entry(1, "one"), entry(2, "two")]).write(to: fixture)
        let support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-SBConnectionsFile", fixture.path, "-SBSupportDir", support.path,
                               "-ApplePersistenceIgnoreState", "YES", "-theme", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["home.select.one"].waitForExistence(timeout: 30))
        app.buttons["home.select.one"].click()
        app.buttons["home.select.two"].click()
        app.buttons["home.connect"].click()
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 180), "the workspace didn't open")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func run(_ sql: String) {
        app.typeKey("6", modifierFlags: .command)
        let editor = element("query.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(sql)
        app.buttons["query.run"].click()
    }

    /// No `table` on the server, and connection one's list knows it: a run that failed
    /// before its cleanup can leave the table behind.
    private func startWithout(_ table: String) {
        element("sidebar.connection.two").click()
        run("DROP TABLE IF EXISTS \(table)")
        element("sidebar.connection.one").click()
        XCTAssertTrue(element("sidebar.refresh").waitForExistence(timeout: 30))
        element("sidebar.refresh").click()
        XCTAssertTrue(waitForGone(element("sidebar.table.\(table)")), "\(table) is still listed")
    }

    private func waitForGone(_ e: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    func testRefreshShowsATableMadeOutsideThisConnection() {
        startWithout("ui_refresh_probe")
        element("sidebar.connection.two").click()
        run("CREATE TABLE ui_refresh_probe (id INT PRIMARY KEY)")
        XCTAssertTrue(element("sidebar.table.ui_refresh_probe").waitForExistence(timeout: 30), "two's own list didn't refresh")

        element("sidebar.connection.one").click()
        XCTAssertFalse(element("sidebar.table.ui_refresh_probe").waitForExistence(timeout: 3))
        element("sidebar.refresh").click()
        XCTAssertTrue(element("sidebar.table.ui_refresh_probe").waitForExistence(timeout: 30), "Refresh didn't show the new table")

        element("sidebar.connection.two").click()
        run("DROP TABLE ui_refresh_probe")
    }

    func testControlCommandRRefreshesTheTables() {
        startWithout("ui_refresh_keys")
        element("sidebar.connection.two").click()
        run("CREATE TABLE ui_refresh_keys (id INT PRIMARY KEY)")
        XCTAssertTrue(element("sidebar.table.ui_refresh_keys").waitForExistence(timeout: 30))
        element("sidebar.connection.one").click()
        XCTAssertFalse(element("sidebar.table.ui_refresh_keys").waitForExistence(timeout: 3))
        app.typeKey("r", modifierFlags: [.command, .control])
        XCTAssertTrue(element("sidebar.table.ui_refresh_keys").waitForExistence(timeout: 30), "⌃⌘R didn't refresh the tables")
        element("sidebar.connection.two").click()
        run("DROP TABLE ui_refresh_keys")
    }

    func testShiftCommandRRefreshesTheConnectionOnScreen() {
        startWithout("ui_refresh_shift")
        element("sidebar.connection.two").click()
        run("CREATE TABLE ui_refresh_shift (id INT PRIMARY KEY)")
        XCTAssertTrue(element("sidebar.table.ui_refresh_shift").waitForExistence(timeout: 30))
        element("sidebar.connection.one").click()
        XCTAssertFalse(element("sidebar.table.ui_refresh_shift").waitForExistence(timeout: 3))
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(element("sidebar.table.ui_refresh_shift").waitForExistence(timeout: 30), "⇧⌘R didn't refresh the connection on screen")
        element("sidebar.connection.two").click()
        run("DROP TABLE ui_refresh_shift")
    }

    func testOptionCommandRRunsEveryStatementAndCommandRTheCurrentOne() {
        run("SELECT 'a-keys' AS a;\nSELECT 'b-keys' AS b")
        let editor = element("query.editor")
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)      // the caret into the first statement
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'a-keys'")).firstMatch.waitForExistence(timeout: 30),
                      "⌘R didn't run the statement under the cursor")
        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'b-keys'")).firstMatch.waitForExistence(timeout: 30),
                      "⌥⌘R didn't run them all")
    }
}
