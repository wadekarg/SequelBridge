//
//  PostgresWorkflowUITests.swift
//  SequelBridgeUITests
//
//  PostgreSQL clicked through the app on a real server: the schemas in the picker, a
//  table's Content and Structure, Explain and a typed SHOW, a cell edited in place.
//  With no SB_UI_PG_PORT the suite is skipped.
//

import XCTest

final class PostgresWorkflowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!
    private let alias = "pg"

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let port = env["SB_UI_PG_PORT"] else { throw XCTSkip("no PostgreSQL for the UI tests (SB_UI_PG_PORT)") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-pg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = dir.appendingPathComponent("connections.json")
        let entry: [String: Any] = [
            "id": "5B0A0000-0000-4000-8000-000000000201", "name": "PostgreSQL", "alias": alias,
            "connectionType": "TCP/IP", "color": "#4F7CAC",
            "host": env["SB_UI_PG_HOST"] ?? "127.0.0.1", "port": Int(port) ?? 5432,
            "username": env["SB_UI_PG_USER"] ?? "sbuser", "password": env["SB_UI_PG_PASS"] ?? "",
            "database": env["SB_UI_PG_DB"] ?? "sbtest", "engine": "postgres", "folder": "", "readOnly": false,
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
        // The first connect downloads DuckDB's PostgreSQL driver.
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 180), "the workspace didn't open")
        XCTAssertTrue(table("customers").waitForExistence(timeout: 60), "public's tables weren't listed")
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

    func testPickingASchemaListsItsTables() {
        XCTAssertEqual(element("sidebar.database").value as? String, "public")
        pick(database: "reporting")
        XCTAssertTrue(table("daily_totals").waitForExistence(timeout: 30), "reporting's tables weren't listed")
        XCTAssertFalse(table("customers").exists)
        XCTAssertFalse(text(containing: "Couldn't open").exists, "picking the schema failed")
    }

    func testContentShowsTheRowsAndStructureTheColumns() {
        table("customers").click()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(element("results.grid").staticTexts["Ada Lovelace"].waitForExistence(timeout: 30), "Content didn't show the rows")
        app.typeKey("1", modifierFlags: .command)
        let column = app.textFields.matching(NSPredicate(format: "value == %@", "credit_limit")).firstMatch
        XCTAssertTrue(column.waitForExistence(timeout: 30), "Structure didn't show the columns")
    }

    func testExplainShowsThePlanAndATypedShowRuns() {
        run("SELECT * FROM customers WHERE id = 1")
        XCTAssertTrue(element("results.grid").staticTexts["Ada Lovelace"].waitForExistence(timeout: 30))
        element("query.explain").click()
        XCTAssertTrue(element("results.grid").buttons["QUERY PLAN"].waitForExistence(timeout: 30), "Explain showed no plan")
        run("SHOW search_path")
        XCTAssertTrue(element("results.grid").buttons["search_path"].waitForExistence(timeout: 30), "SHOW didn't run")
    }

    func testCreateTableOffersNoMySQLOnlyOptions() {
        element("sidebar.createTable").click()
        XCTAssertTrue(app.staticTexts["Table Settings"].waitForExistence(timeout: 10), "the Create Table sheet didn't open")
        XCTAssertFalse(app.staticTexts["Engine"].exists, "PostgreSQL has no storage engine to pick")
        XCTAssertFalse(app.staticTexts["Charset"].exists, "PostgreSQL has no per-table charset to pick")
        app.windows.buttons["Cancel"].click()   // not the Touch Bar's copy
    }

    func testEditACellInPlace() {
        run("CREATE SCHEMA IF NOT EXISTS sbui; DROP TABLE IF EXISTS sbui.ui_cells; "
            + "CREATE TABLE sbui.ui_cells (id int PRIMARY KEY, note varchar(40)); INSERT INTO sbui.ui_cells VALUES (1, 'before')")
        pick(database: "sbui")
        XCTAssertTrue(table("ui_cells").waitForExistence(timeout: 30), "the new table didn't appear in the left panel")
        table("ui_cells").click()
        app.typeKey("2", modifierFlags: .command)
        let cell = element("results.grid").staticTexts["before"]
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "the Content tab didn't show the row")
        cell.doubleClick()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("after\r")
        run("SELECT 'note=' || note AS v FROM sbui.ui_cells WHERE id = 1")
        XCTAssertTrue(text(containing: "note=after").waitForExistence(timeout: 30), "the in-place edit wasn't saved")
        run("DROP SCHEMA sbui CASCADE")
    }
}
