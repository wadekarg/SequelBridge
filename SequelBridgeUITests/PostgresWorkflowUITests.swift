//
//  PostgresWorkflowUITests.swift
//  SequelBridgeUITests
//
//  PostgreSQL clicked through the app on a real server: the schemas in the picker, a
//  table's Content and Structure, Explain and a typed SHOW, a cell edited in place, a
//  result in another schema edited in its popup, Run Current. The subclasses run every
//  one of them again through an SSH tunnel and a Unix socket. With no SB_UI_PG_PORT the
//  suite is skipped.
//

import XCTest

class PostgresWorkflowUITests: XCTestCase {
    var app: XCUIApplication!
    private var dir: URL!
    let alias = "pg"

    var env: [String: String] { ProcessInfo.processInfo.environment }

    /// The connection to make: TCP/IP here; the subclasses go through SSH and a socket.
    func connectionEntry(port: Int) throws -> [String: Any] {
        [
            "id": "5B0A0000-0000-4000-8000-000000000201", "name": "PostgreSQL", "alias": alias,
            "connectionType": "TCP/IP", "color": "#4F7CAC",
            "host": env["SB_UI_PG_HOST"] ?? "127.0.0.1", "port": port,
            "username": env["SB_UI_PG_USER"] ?? "sbuser", "password": env["SB_UI_PG_PASS"] ?? "",
            "database": env["SB_UI_PG_DB"] ?? "sbtest", "engine": "postgres", "folder": "", "readOnly": false,
        ]
    }

    /// Extra launch arguments (through SSH, a known-hosts file of its own).
    func launchArguments(in dir: URL) throws -> [String] { [] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let port = env["SB_UI_PG_PORT"] else { throw XCTSkip("no PostgreSQL for the UI tests (SB_UI_PG_PORT)") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-pg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = dir.appendingPathComponent("connections.json")
        try JSONSerialization.data(withJSONObject: [try connectionEntry(port: Int(port) ?? 5432)]).write(to: fixture)
        let support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchArguments = ["-SBConnectionsFile", fixture.path, "-SBSupportDir", support.path,
                               "-ApplePersistenceIgnoreState", "YES", "-theme", "Light"] + (try launchArguments(in: dir))
        app.launch()
        XCTAssertTrue(app.buttons["home.select.\(alias)"].waitForExistence(timeout: 30), "Home didn't show the connection")
        app.buttons["home.select.\(alias)"].click()
        app.buttons["home.connect"].click()
        // Through SSH, a server met for the first time is trusted (SSHHostKeyUITests covers that question).
        dialogButton("Trust and Connect", timeout: 8)?.click()
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 180), "the workspace didn't open")
        XCTAssertTrue(table("customers").waitForExistence(timeout: 60), "public's tables weren't listed")
    }

    override func tearDownWithError() throws {
        // Quit as a person does: the app ends its ssh tunnels (terminate() leaves them).
        if let app, app.state != .notRunning {
            app.typeKey("q", modifierFlags: .command)
            if !app.wait(for: .notRunning, timeout: 15) { app.terminate() }
        }
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

    /// A button of the question on screen (a sheet over the window), not the Touch Bar's copy.
    private func dialogButton(_ title: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for b in [app.sheets.buttons[title], app.dialogs.buttons[title], app.windows.buttons[title]] where b.exists { return b }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return nil
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

    /// A read in a schema other than public runs on the app's own client: its rows came
    /// back with no table to save an edit to.
    func testAResultInAnotherSchemaIsEditedInItsPopup() throws {
        run("CREATE SCHEMA IF NOT EXISTS sbuipop; DROP TABLE IF EXISTS sbuipop.ui_pop; "
            + "CREATE TABLE sbuipop.ui_pop (id int PRIMARY KEY, note varchar(40)); INSERT INTO sbuipop.ui_pop VALUES (1, 'before')")
        pick(database: "sbuipop")
        XCTAssertTrue(table("ui_pop").waitForExistence(timeout: 30), "the new table didn't appear in the left panel")
        run("SELECT id, note FROM ui_pop")
        let cell = element("results.grid").staticTexts["before"]
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "the result didn't show the row")
        cell.doubleClick()
        let edit = app.popovers.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "double-click opened no popup with Edit")
        edit.click()
        let field = app.popovers.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Edit gave nothing to type in")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("after")
        app.popovers.buttons["Save"].click()
        run("SELECT 'note=' || note AS v FROM sbuipop.ui_pop WHERE id = 1")
        XCTAssertTrue(text(containing: "note=after").waitForExistence(timeout: 30), "the popup's Save didn't write the value")
        run("DROP SCHEMA sbuipop CASCADE")
    }

    /// Run Current read #>> (PostgreSQL's JSON path operator) as a MySQL # comment: the
    /// statement under the caret ran together with the one before it.
    func testRunCurrentRunsTheStatementUnderTheCaret() {
        app.typeKey("6", modifierFlags: .command)
        let editor = element("query.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no SQL editor")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("SELECT nosuch #>> '{a}' FROM customers;\nSELECT 'second=' || 2 AS v")    // the caret ends in the second
        element("query.runCurrent").click()
        XCTAssertTrue(text(containing: "second=2").waitForExistence(timeout: 30), "Run Current didn't run the statement under the caret")
        XCTAssertFalse(text(containing: "nosuch").exists, "the statement before it ran too")
    }
}

/// The same flows through an SSH tunnel to the same PostgreSQL (the test SSH server sees it
/// at host.docker.internal). Needs SB_UI_SSH_KEY.
final class PostgresWorkflowOverSSHUITests: PostgresWorkflowUITests {
    override func connectionEntry(port: Int) throws -> [String: Any] {
        guard let key = env["SB_UI_SSH_KEY"] else { throw XCTSkip("no SSH server for the UI tests (SB_UI_SSH_KEY)") }
        var entry = try super.connectionEntry(port: port)
        entry["id"] = "5B0A0000-0000-4000-8000-000000000202"
        entry["connectionType"] = "SSH"
        entry["host"] = env["SB_UI_SSH_DB_HOST"] ?? "host.docker.internal"
        entry["sshHost"] = "127.0.0.1"
        entry["sshPort"] = Int(env["SB_UI_SSH_PORT"] ?? "") ?? 2224
        entry["sshUsername"] = "tunneluser"
        entry["sshKeyPath"] = key
        return entry
    }

    /// A known-hosts file of its own, never the Mac's.
    override func launchArguments(in dir: URL) throws -> [String] {
        let file = dir.appendingPathComponent("known_hosts")
        try "".write(to: file, atomically: true, encoding: .utf8)
        return ["-SBKnownHostsFile", file.path]
    }
}

/// The same flows through a Unix socket (a relay to the same PostgreSQL): the socket's
/// directory, and the port that names the socket in it. Needs SB_UI_PG_SOCKET_DIR.
final class PostgresWorkflowOverSocketUITests: PostgresWorkflowUITests {
    override func connectionEntry(port: Int) throws -> [String: Any] {
        guard let socketDir = env["SB_UI_PG_SOCKET_DIR"] else { throw XCTSkip("no PostgreSQL socket for the UI tests (SB_UI_PG_SOCKET_DIR)") }
        var entry = try super.connectionEntry(port: port)
        entry["id"] = "5B0A0000-0000-4000-8000-000000000203"
        entry["connectionType"] = "Socket"
        entry["socketPath"] = socketDir
        return entry
    }
}
