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

    func testASavedQueryLoadsBackIntoATab() {
        let sql = "SELECT CONCAT('saved-', 42) AS v"
        run(sql)
        XCTAssertTrue(text(containing: "saved-42").waitForExistence(timeout: 30))
        element("query.savedQueries").click()
        app.menuItems["Save Current Query…"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Save Current Query… opened no sheet")
        let name = sheet.textFields.firstMatch
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("ui saved query")
        sheet.buttons["Save"].click()
        XCTAssertTrue(waitForGone(sheet), "Save left the sheet open")
        element("query.newTab").click()
        element("query.savedQueries").click()
        app.menuItems["ui saved query"].click()
        app.menuItems["Load into current tab"].click()
        let editor = element("query.editor")
        let loaded = expectation(for: NSPredicate(format: "value == %@", sql), evaluatedWith: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed, "the saved query didn't load into the tab")
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

    // DuckDB used to read these first: it refused MySQL's own syntax (backticks,
    // AUTO_INCREMENT, UNSIGNED, "double-quoted" strings, ON DUPLICATE KEY UPDATE) and
    // made a VARCHAR(40) column TEXT. They run on the server as typed now.
    func testMySQLsOwnSyntaxRunsAsTyped() {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_typed; CREATE TABLE `ui_typed` (id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY, note VARCHAR(40)) ENGINE=InnoDB; "
            + "INSERT INTO ui_typed (note) VALUES (\"typed\") ON DUPLICATE KEY UPDATE note = 'again'")
        XCTAssertTrue(element("results.grid").buttons["Affected rows"].waitForExistence(timeout: 30), "the run didn't say how many rows it changed")
        run("SELECT CONCAT('note=', note, ' type=', (SELECT COLUMN_TYPE FROM information_schema.COLUMNS "
            + "WHERE TABLE_SCHEMA = 'sbwrite' AND TABLE_NAME = 'ui_typed' AND COLUMN_NAME = 'note')) AS v FROM ui_typed")
        XCTAssertTrue(text(containing: "note=typed type=varchar(40)").waitForExistence(timeout: 30), "the table or its row isn't as typed")
        run("DROP TABLE ui_typed")
    }

    // MySQL can't prepare these, and the passthrough prepares every statement: typed in
    // the Query tab they failed ("Failed to fetch return types"). The app's own client
    // runs them now.
    func testShowCreateTableAndProcesslistTypedInTheQueryTab() {
        pick(database: "sbtest")
        run("SHOW CREATE TABLE customers")
        XCTAssertTrue(element("results.grid").buttons["Create Table"].waitForExistence(timeout: 30), "SHOW CREATE TABLE showed no statement")
        XCTAssertTrue(text(containing: "CREATE TABLE `customers`").waitForExistence(timeout: 10))
        run("SHOW FULL PROCESSLIST")
        XCTAssertTrue(element("results.grid").buttons["Command"].waitForExistence(timeout: 30), "SHOW FULL PROCESSLIST showed no processes")
    }

    // A keyboard shortcut runs the action its button had when first drawn. Before each
    // table had a panel of its own, ⌘R on the second table opened in Content or Structure
    // reloaded the first table's rows or columns, under the second table's name.
    func testCommandRReloadsTheTableOnScreenNotTheFirstOne() {
        let grid = element("results.grid")
        table("customers").click()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(grid.staticTexts["Ada Lovelace"].waitForExistence(timeout: 30), "Content didn't show customers")
        table("orders").click()
        XCTAssertTrue(grid.staticTexts["shipped"].waitForExistence(timeout: 30), "Content didn't show orders")
        app.typeKey("r", modifierFlags: .command)
        XCTAssertFalse(grid.staticTexts["Ada Lovelace"].waitForExistence(timeout: 5), "Content's ⌘R reloaded the first table's rows")
        XCTAssertTrue(grid.staticTexts["shipped"].exists)

        table("customers").click()
        app.typeKey("1", modifierFlags: .command)
        let column = { (name: String) in self.app.textFields.matching(NSPredicate(format: "value == %@", name)).firstMatch }
        XCTAssertTrue(column("email").waitForExistence(timeout: 30), "Structure didn't show customers")
        table("orders").click()
        XCTAssertTrue(column("total").waitForExistence(timeout: 30), "Structure didn't show orders")
        app.typeKey("r", modifierFlags: .command)
        XCTAssertFalse(column("email").waitForExistence(timeout: 5), "Structure's ⌘R reloaded the first table's columns")
        XCTAssertTrue(column("total").exists)
    }

    // From the visual tour (VisualTourUITests): a cell that wrapped, a label that misnamed.
    func testStructureCellsStayOnOneLine() {
        continueAfterFailure = true      // each check stands alone
        table("orders").click()
        app.typeKey("1", modifierFlags: .command)
        let placedAt = element("structure.default.placed_at")
        XCTAssertTrue(placedAt.waitForExistence(timeout: 30), "Structure didn't show placed_at")
        XCTAssertLessThan(placedAt.frame.height, 20, "CURRENT_TIMESTAMP wrapped onto two lines")
        XCTAssertTrue(app.staticTexts["collation"].waitForExistence(timeout: 15), "the left panel's table information has no collation")
        XCTAssertFalse(app.staticTexts["encoding"].exists, "a collation is shown as the encoding")
    }

    // From the visual tour: buttons smaller or bigger than the ones beside them, and a Go that was off.
    func testToolbarButtonsMatchTheirNeighbours() {
        continueAfterFailure = true      // each check stands alone
        app.typeKey("6", modifierFlags: .command)
        let runCurrent = element("query.runCurrent"), format = element("query.format")
        XCTAssertTrue(runCurrent.waitForExistence(timeout: 10), "no Run Current")
        XCTAssertEqual(runCurrent.frame.height, format.frame.height, accuracy: 2, "Run Current is smaller than Format beside it")

        table("orders").click()
        app.typeKey("2", modifierFlags: .command)
        let refresh = element("content.refresh"), add = element("content.addRow")
        XCTAssertTrue(refresh.waitForExistence(timeout: 30), "no Content refresh")
        XCTAssertEqual(refresh.frame.height, add.frame.height, accuracy: 2, "Content's refresh is bigger than the buttons beside it")
        app.typeKey("j", modifierFlags: .command)
        let go = element("content.pageGo")
        XCTAssertTrue(go.waitForExistence(timeout: 10), "⌘J didn't open the page options")
        XCTAssertTrue(go.isEnabled, "Go is off though the field holds the page on screen")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testFilterRowsWithAColumnAnOperatorAndAValue() {
        table("orders").click()
        app.typeKey("2", modifierFlags: .command)
        let grid = element("results.grid")
        XCTAssertTrue(grid.staticTexts["shipped"].waitForExistence(timeout: 30), "the Content tab didn't show the rows")
        element("content.filterToggle").click()
        let column = element("content.filterColumn")
        XCTAssertTrue(column.waitForExistence(timeout: 10), "no column picker")
        column.click()
        app.menuItems["status"].click()
        let value = element("content.filterValue")
        value.click()
        value.typeText("paid\r")
        XCTAssertTrue(waitForGone(grid.staticTexts["shipped"]), "status = paid didn't filter the rows")
        XCTAssertTrue(grid.staticTexts["paid"].exists)

        element("content.filterOperator").click()
        app.menuItems["contains"].click()
        value.click()
        value.typeKey("a", modifierFlags: .command)
        value.typeText("ipp\r")
        XCTAssertTrue(grid.staticTexts["shipped"].waitForExistence(timeout: 30), "contains ipp didn't find shipped")
        XCTAssertFalse(grid.staticTexts["paid"].exists)
    }

    func testFollowAForeignKeyToTheRowItPointsAt() {
        table("orders").click()
        app.typeKey("2", modifierFlags: .command)
        let grid = element("results.grid")
        XCTAssertTrue(grid.staticTexts["shipped"].waitForExistence(timeout: 30), "the Content tab didn't show the rows")
        // Order 3 belongs to customer 2: its customer_id cell, after # and id.
        grid.tableRows.element(boundBy: 2).cells.element(boundBy: 2).rightClick()
        let go = app.menuItems["Go to customers where id = 2"]
        XCTAssertTrue(go.waitForExistence(timeout: 10), "a customer_id cell doesn't lead to its customer")
        go.click()
        XCTAssertTrue(grid.staticTexts["Alan Turing"].waitForExistence(timeout: 30), "customer 2 isn't shown")
        XCTAssertFalse(grid.staticTexts["Ada Lovelace"].exists, "the other customers are still shown")
        XCTAssertEqual(element("content.filterValue").value as? String, "2", "the filter doesn't show the key's value")
    }

    func testAddADatabaseWithItsEncodingThenDeleteIt() {
        run("DROP DATABASE IF EXISTS ui_added")       // what a run that failed half-way left
        element("sidebar.databaseMenu").click()
        app.menuItems["Add Database…"].click()
        let name = element("addDatabase.name")
        XCTAssertTrue(name.waitForExistence(timeout: 10), "no Add Database sheet")
        name.click()
        name.typeText("ui_added")
        element("addDatabase.charset").click()
        app.menuItems["latin1"].click()
        element("addDatabase.collation").click()
        app.menuItems["latin1_general_ci"].click()
        element("addDatabase.add").click()
        XCTAssertTrue(waitForValue(element("sidebar.database"), "ui_added"), "the new database isn't picked")
        run("SELECT CONCAT('cs=', DEFAULT_CHARACTER_SET_NAME, ' co=', DEFAULT_COLLATION_NAME) AS v FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'ui_added'")
        XCTAssertTrue(text(containing: "cs=latin1 co=latin1_general_ci").waitForExistence(timeout: 30), "not made with the encoding picked")

        element("sidebar.databaseMenu").click()
        app.menuItems["Delete Database “ui_added”…"].click()
        // In the window: a MacBook's Touch Bar shows a dialog's buttons too, a second match.
        let confirm = app.windows.buttons["Delete “ui_added”"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no confirmation")
        confirm.click()
        XCTAssertTrue(waitForValue(element("sidebar.database"), "sbtest"), "didn't go back to the connection's own database")
    }

    func testTableMaintenanceShowsTheServersAnswer() {
        table("orders").rightClick()
        let menu = app.menuItems["Table Maintenance"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no Table Maintenance on the table's menu")
        menu.click()
        app.menuItems["Check Table"].click()
        XCTAssertTrue(app.staticTexts["status: OK"].waitForExistence(timeout: 30), "CHECK TABLE's answer isn't shown")
        app.windows.buttons["OK"].click()
    }

    // The README promises the Console shows every statement the app runs; its own reads
    // (the columns Structure lists) were never logged.
    func testConsoleShowsTheAppsOwnReadsMarkedAndYoursAlone() {
        run("SELECT 'yours-probe' AS v")
        XCTAssertTrue(text(containing: "yours-probe").waitForExistence(timeout: 30))
        table("orders").click()
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(element("structure.addColumn").waitForExistence(timeout: 15))
        app.typeKey("9", modifierFlags: .command)
        XCTAssertTrue(text(containing: "SHOW FULL COLUMNS FROM `sbtest`.`orders`").waitForExistence(timeout: 15),
                      "Structure's read of the columns isn't in the Console")
        XCTAssertTrue(app.staticTexts["by the app"].exists, "the app's read isn't marked as the app's")
        app.radioButtons["Yours"].click()
        XCTAssertTrue(waitForGone(text(containing: "SHOW FULL COLUMNS")), "Yours still lists the app's reads")
        XCTAssertTrue(text(containing: "yours-probe").exists, "Yours dropped your own statement")
    }

    func testJumpToAPageAndChangeTheRowsPerPage() {
        pick(database: "sbwrite")
        // Rows 1001–1300; a page starts with the id of its first row.
        let digit = "(SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9)"
        run("DROP TABLE IF EXISTS ui_pages; CREATE TABLE ui_pages (id INT PRIMARY KEY); "
            + "INSERT INTO ui_pages SELECT 1001 + a.d * 100 + b.d * 10 + c.d FROM (SELECT 0 d UNION SELECT 1 UNION SELECT 2) a, \(digit) b, \(digit) c")
        XCTAssertTrue(table("ui_pages").waitForExistence(timeout: 30))
        table("ui_pages").click()
        app.typeKey("2", modifierFlags: .command)
        let grid = element("results.grid")
        XCTAssertTrue(grid.staticTexts["1001"].waitForExistence(timeout: 30), "the Content tab didn't show the rows")

        app.typeKey("j", modifierFlags: .command)
        let size = element("content.pageSize")
        XCTAssertTrue(size.waitForExistence(timeout: 10), "⌘J didn't open the page options")
        size.click()
        app.menuItems["100"].click()
        app.typeKey(.escape, modifierFlags: [])
        element("content.nextPage").click()
        XCTAssertTrue(grid.staticTexts["1101"].waitForExistence(timeout: 30), "the second page doesn't start at row 101: the page size isn't 100")

        app.typeKey("j", modifierFlags: .command)
        let field = element("content.pageField")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no page field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("3\r")
        XCTAssertTrue(grid.staticTexts["1201"].waitForExistence(timeout: 30), "the jump didn't reach page 3")
        XCTAssertFalse(grid.staticTexts["1101"].exists)
        run("DROP TABLE ui_pages")
    }

    func testCommandDDuplicatesTheSelectedRow() {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_dup; CREATE TABLE ui_dup (id INT AUTO_INCREMENT PRIMARY KEY, status VARCHAR(20), note VARCHAR(20) NULL); "
            + "INSERT INTO ui_dup (status, note) VALUES ('dup-paid', NULL)")
        XCTAssertTrue(table("ui_dup").waitForExistence(timeout: 30))
        table("ui_dup").click()
        app.typeKey("2", modifierFlags: .command)
        let cell = element("results.grid").staticTexts["dup-paid"]
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "the Content tab didn't show the row")
        cell.click()
        app.typeKey("d", modifierFlags: .command)
        let insert = element("rowSheet.insert")
        XCTAssertTrue(insert.waitForExistence(timeout: 10), "⌘D didn't open the row sheet")
        XCTAssertEqual(element("rowSheet.field.status").value as? String, "dup-paid", "the copy didn't start from the row's values")
        insert.click()
        // A copied key would clash with the first row's; the server numbers the copy.
        run("SELECT CONCAT('copies=', COUNT(*), ' nulls=', SUM(note IS NULL), ' ids=', GROUP_CONCAT(id ORDER BY id)) AS v FROM ui_dup WHERE status = 'dup-paid'")
        XCTAssertTrue(text(containing: "copies=2 nulls=2 ids=1,2").waitForExistence(timeout: 30), "the row wasn't duplicated as it was")
        run("DROP TABLE ui_dup")
    }

    private func waitForValue(_ e: XCUIElement, _ value: String, timeout: TimeInterval = 30) -> Bool {
        let shown = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: e)
        return XCTWaiter.wait(for: [shown], timeout: timeout) == .completed
    }

    private func waitForGone(_ e: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }
}
