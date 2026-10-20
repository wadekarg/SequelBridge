//
//  MySQLWorkflowUITests.swift
//  SequelBridgeUITests
//
//  The everyday flows from the Sequel Ace checklist (guide/SEQUEL-ACE.md, the ● rows),
//  clicked through the app on a real MariaDB: pick a database, USE, several statements,
//  filter tables, edit a cell in place and set it to NULL, the ⌘1–⌘6 tabs, the Console.
//  On GitHub the workflow installs MariaDB and seeds scripts/fixtures/mysql.sql; with no
//  SB_UI_MYSQL_PORT the suite is skipped.
//

import XCTest

final class MySQLWorkflowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!
    private let alias = "my"

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let port = env["SB_UI_MYSQL_PORT"] else { throw XCTSkip("no MariaDB for the UI tests (SB_UI_MYSQL_PORT)") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-my-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = dir.appendingPathComponent("connections.json")
        let entry: [String: Any] = [
            "id": "5B0A0000-0000-4000-8000-000000000101", "name": "MariaDB", "alias": alias,
            "connectionType": "TCP/IP", "color": "#3A9AA8",
            "host": env["SB_UI_MYSQL_HOST"] ?? "127.0.0.1", "port": Int(port) ?? 3306,
            "username": env["SB_UI_MYSQL_USER"] ?? "sbui", "password": env["SB_UI_MYSQL_PASS"] ?? "",
            "database": "sbtest", "engine": "mysql", "folder": "", "readOnly": false,
        ]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: fixture)
        let support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchArguments = ["-SBConnectionsFile", fixture.path, "-SBSupportDir", support.path,
                               "-ApplePersistenceIgnoreState", "YES", "-theme", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["home.select.\(alias)"].waitForExistence(timeout: 30), "Home didn't show the connection")
        app.buttons["home.select.\(alias)"].click()
        app.buttons["home.connect"].click()
        // The first connect downloads DuckDB's MySQL driver.
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 180), "the workspace didn't open")
        XCTAssertTrue(table("orders").waitForExistence(timeout: 60), "sbtest's tables weren't listed")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func table(_ name: String) -> XCUIElement { element("sidebar.table.\(name)") }

    private func text(containing s: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", s)).firstMatch
    }

    /// Replaces the editor's text with `sql` and runs it, on the Query tab.
    private func run(_ sql: String) {
        app.typeKey("6", modifierFlags: .command)
        let editor = element("query.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no SQL editor")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(sql)
        app.buttons["query.run"].click()
    }

    private func pick(database: String) {
        let picker = element("sidebar.database")
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no database picker")
        picker.click()
        app.menuItems[database].click()
    }

    // MARK: - Flows

    func testPickingADatabaseListsItsTables() {
        pick(database: "sbreal")
        XCTAssertTrue(table("legacy_notes").waitForExistence(timeout: 30), "sbreal's tables weren't listed")
        XCTAssertFalse(table("orders").exists)
    }

    func testUseSwitchesTheDatabaseAtTheTopLeft() {
        run("USE sbreal")
        XCTAssertTrue(text(containing: "Database changed to sbreal").waitForExistence(timeout: 30))
        XCTAssertTrue(table("legacy_notes").waitForExistence(timeout: 30), "the left panel didn't follow USE")
        XCTAssertEqual(element("sidebar.database").value as? String, "sbreal")
        run("SELECT note FROM legacy_notes ORDER BY id LIMIT 1")
        XCTAssertTrue(text(containing: "ground stop review").waitForExistence(timeout: 30), "the next statement didn't run in sbreal")
    }

    func testSeveralStatementsRunInTurnAndShowTheLast() {
        run("SELECT 'first-result' AS a; SELECT 'second-result' AS b")
        XCTAssertTrue(text(containing: "second-result").waitForExistence(timeout: 30), "the last statement's result isn't shown")
        XCTAssertFalse(text(containing: "first-result").exists)
        run("SELECT 'ok-one'; SELECT * FROM no_such_table_here")
        XCTAssertTrue(text(containing: "Statement 2 of 2").waitForExistence(timeout: 30), "the failing statement wasn't named")
    }

    func testFilterTables() {
        let filter = element("sidebar.filter")
        filter.click()
        filter.typeText("order")
        XCTAssertTrue(table("orders").waitForExistence(timeout: 10))
        XCTAssertTrue(table("order_items").exists)
        XCTAssertFalse(table("customers").exists)
    }

    func testEditACellInPlaceThenSetItToNULL() {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_cells; CREATE TABLE ui_cells (id INT PRIMARY KEY, note VARCHAR(40)); INSERT INTO ui_cells VALUES (1, 'before')")
        XCTAssertTrue(table("ui_cells").waitForExistence(timeout: 30), "the new table didn't appear in the left panel")
        table("ui_cells").click()
        app.typeKey("2", modifierFlags: .command)
        let cell = element("results.grid").staticTexts["before"]
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "the Content tab didn't show the row")
        cell.doubleClick()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("after\r")
        run("SELECT CONCAT('note=', note) AS v FROM ui_cells WHERE id = 1")
        XCTAssertTrue(text(containing: "note=after").waitForExistence(timeout: 30), "the in-place edit wasn't saved")

        table("ui_cells").click()
        app.typeKey("2", modifierFlags: .command)
        let edited = element("results.grid").staticTexts["after"]
        XCTAssertTrue(edited.waitForExistence(timeout: 30))
        edited.rightClick()
        app.menuItems["Set to NULL"].click()
        run("SELECT CONCAT('null=', note IS NULL) AS v FROM ui_cells WHERE id = 1")
        XCTAssertTrue(text(containing: "null=1").waitForExistence(timeout: 30), "Set to NULL didn't store NULL")
        run("DROP TABLE ui_cells")
        XCTAssertTrue(waitForGone(table("ui_cells")), "the dropped table stayed in the left panel")
    }

    func testCommandNumberSwitchesTheTabs() {
        table("customers").click()
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(element("structure.addColumn").waitForExistence(timeout: 15), "⌘1 didn't show Structure")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(element("content.refresh").waitForExistence(timeout: 15), "⌘2 didn't show Content")
        app.typeKey("6", modifierFlags: .command)
        XCTAssertTrue(element("query.editor").waitForExistence(timeout: 15), "⌘6 didn't show Query")
    }

    func testConsoleShowsStatementsAndClears() {
        run("SELECT 'console-probe' AS v")
        XCTAssertTrue(text(containing: "console-probe").waitForExistence(timeout: 30))
        app.typeKey("9", modifierFlags: .command)
        XCTAssertTrue(text(containing: "console-probe").waitForExistence(timeout: 15), "the Console didn't list the statement")
        element("console.clear").click()
        XCTAssertTrue(waitForGone(text(containing: "console-probe")), "Clear didn't empty the Console")
    }

    func testRenameAndDuplicateATableFromItsMenu() {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_named; DROP TABLE IF EXISTS ui_renamed; DROP TABLE IF EXISTS ui_renamed_copy; CREATE TABLE ui_named (id INT PRIMARY KEY)")
        XCTAssertTrue(table("ui_named").waitForExistence(timeout: 30))
        table("ui_named").rightClick()
        app.menuItems["Rename Table…"].click()
        let field = element("tableName.field")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no name field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("ui_renamed")
        element("tableName.confirm").click()
        XCTAssertTrue(table("ui_renamed").waitForExistence(timeout: 30), "the renamed table isn't listed")
        XCTAssertFalse(table("ui_named").exists)

        table("ui_renamed").rightClick()
        app.menuItems["Duplicate Table…"].click()
        XCTAssertTrue(element("tableName.confirm").waitForExistence(timeout: 10))
        element("tableName.confirm").click()
        XCTAssertTrue(table("ui_renamed_copy").waitForExistence(timeout: 30), "the copy isn't listed")
        run("DROP TABLE ui_renamed; DROP TABLE ui_renamed_copy")
    }

    func testRunCurrentRunsTheStatementUnderTheCursor() {
        run("SELECT 'first-current' AS a;\nSELECT 'second-current' AS b")
        XCTAssertTrue(text(containing: "second-current").waitForExistence(timeout: 30))
        let editor = element("query.editor")
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)       // the caret to the start: the first statement
        element("query.runCurrent").click()
        XCTAssertTrue(text(containing: "first-current").waitForExistence(timeout: 30), "Run Current didn't run the first statement")
        XCTAssertFalse(text(containing: "second-current").exists)
    }

    func testCommandSlashCommentsTheLine() {
        app.typeKey("6", modifierFlags: .command)
        let editor = element("query.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("SELECT 1")
        editor.typeKey("/", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "-- SELECT 1")
        editor.typeKey("/", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "SELECT 1")
    }

    func testTableInfoShowsTheServersOwnCreateTable() {
        table("orders").click()
        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(text(containing: "CONSTRAINT `fk_orders_customer` FOREIGN KEY").waitForExistence(timeout: 30),
                      "Table Info didn't show the server's CREATE TABLE with its foreign key")
    }

    private func waitForGone(_ e: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }
}
