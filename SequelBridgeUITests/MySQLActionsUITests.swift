//
//  MySQLActionsUITests.swift
//  SequelBridgeUITests
//
//  What changes or removes data and schema, clicked through on MariaDB: deleting rows,
//  truncating and dropping a table, dropping a foreign key and a trigger (each asks
//  first, and Cancel leaves everything), adding a row, and stopping a long query. They
//  ran on one click before. MySQLActionsOverSSHUITests runs every one of them again
//  through an SSH tunnel. With no SB_UI_MYSQL_PORT the suite is skipped.
//

import XCTest

class MySQLActionsUITests: XCTestCase {
    var app: XCUIApplication!
    private var dir: URL!
    let alias = "my"

    var env: [String: String] { ProcessInfo.processInfo.environment }

    /// The connection to make: TCP/IP here; a subclass goes through SSH.
    func connectionEntry(port: Int) throws -> [String: Any] {
        [
            "id": "5B0A0000-0000-4000-8000-000000000601", "name": "MariaDB", "alias": alias,
            "connectionType": "TCP/IP", "color": "#3A9AA8",
            "host": env["SB_UI_MYSQL_HOST"] ?? "127.0.0.1", "port": port,
            "username": env["SB_UI_MYSQL_USER"] ?? "sbui", "password": env["SB_UI_MYSQL_PASS"] ?? "",
            "database": "sbtest", "engine": "mysql", "folder": "", "readOnly": false,
        ]
    }

    /// Extra launch arguments (a subclass gives SSH a known-hosts file of its own).
    func launchArguments(in dir: URL) throws -> [String] { [] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let port = env["SB_UI_MYSQL_PORT"] else { throw XCTSkip("no MariaDB for the UI tests (SB_UI_MYSQL_PORT)") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-act-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = dir.appendingPathComponent("connections.json")
        try JSONSerialization.data(withJSONObject: [try connectionEntry(port: Int(port) ?? 3306)]).write(to: fixture)
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
        XCTAssertTrue(table("orders").waitForExistence(timeout: 60), "sbtest's tables weren't listed")
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

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func table(_ name: String) -> XCUIElement { element("sidebar.table.\(name)") }

    func text(containing s: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", s)).firstMatch
    }

    /// Replaces the editor's text with `sql` and runs it, on the Query tab.
    func run(_ sql: String) {
        app.typeKey("6", modifierFlags: .command)
        let editor = element("query.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no SQL editor")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(sql)
        app.buttons["query.run"].click()
    }

    /// Runs `sql` and waits for its one value, "label=value".
    func expectValue(_ sql: String, _ shown: String, _ why: String) {
        run(sql)
        XCTAssertTrue(text(containing: shown).waitForExistence(timeout: 30), why)
    }

    func pick(database: String) {
        let picker = element("sidebar.database")
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no database picker")
        picker.click()
        app.menuItems[database].click()
    }

    /// A button of the question on screen (a sheet over the window), not the Touch Bar's copy.
    func dialogButton(_ title: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for b in [app.sheets.buttons[title], app.dialogs.buttons[title], app.windows.buttons[title]] where b.exists { return b }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return nil
    }

    func waitForGone(_ e: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    /// Narrows the window as far as it goes (its minimum is 800 points) by dragging its
    /// right edge, as a person does.
    func narrowWindow() {
        let window = app.windows.firstMatch
        let before = window.frame.width
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: 1, dy: 0))
        edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: 500 - before, dy: 0)))
        XCTAssertLessThan(window.frame.width, before, "the window didn't narrow")
    }

    // MARK: - Flows

    func testDeletingRowsAsksFirstAndCancelKeepsThem() throws {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_del; CREATE TABLE ui_del (id INT PRIMARY KEY, note VARCHAR(20)); INSERT INTO ui_del VALUES (1, 'keep'), (2, 'gone')")
        XCTAssertTrue(table("ui_del").waitForExistence(timeout: 30), "the new table didn't appear in the left panel")
        table("ui_del").click()
        app.typeKey("2", modifierFlags: .command)
        let gone = element("results.grid").staticTexts["gone"]
        XCTAssertTrue(gone.waitForExistence(timeout: 30), "the Content tab didn't show the rows")
        gone.click()
        element("content.deleteRows").click()
        try XCTUnwrap(dialogButton("Cancel"), "deleting a row didn't ask first").click()
        XCTAssertTrue(gone.exists, "Cancel deleted the row")
        element("content.deleteRows").click()
        try XCTUnwrap(dialogButton("Delete Row"), "no Delete Row in the question").click()
        XCTAssertTrue(waitForGone(gone), "the deleted row stayed on screen")
        expectValue("SELECT CONCAT('left=', COUNT(*), ':', MIN(note)) AS v FROM ui_del", "left=1:keep", "the wrong rows were deleted")
        run("DROP TABLE ui_del")
    }

    func testAddRowInContent() throws {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_add; CREATE TABLE ui_add (id INT PRIMARY KEY, note VARCHAR(20))")
        XCTAssertTrue(table("ui_add").waitForExistence(timeout: 30))
        table("ui_add").click()
        app.typeKey("2", modifierFlags: .command)
        element("content.addRow").click()
        let id = element("rowSheet.field.id"), note = element("rowSheet.field.note")
        XCTAssertTrue(id.waitForExistence(timeout: 10), "Add Row didn't open the row sheet")
        id.click(); id.typeText("7")
        note.click(); note.typeText("added")
        element("rowSheet.insert").click()
        XCTAssertTrue(element("results.grid").staticTexts["added"].waitForExistence(timeout: 30), "the new row isn't shown")
        expectValue("SELECT CONCAT('row=', id, ':', note) AS v FROM ui_add", "row=7:added", "the row wasn't added")
        run("DROP TABLE ui_add")
    }

    func testTruncateAndDropTableAskFirst() throws {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_drop; CREATE TABLE ui_drop (id INT PRIMARY KEY); INSERT INTO ui_drop VALUES (1), (2)")
        XCTAssertTrue(table("ui_drop").waitForExistence(timeout: 30))
        table("ui_drop").rightClick()
        app.menuItems["Truncate Table…"].click()
        try XCTUnwrap(dialogButton("Cancel"), "Truncate didn't ask first").click()
        expectValue("SELECT CONCAT('kept=', COUNT(*)) AS v FROM ui_drop", "kept=2", "Cancel emptied the table")
        table("ui_drop").rightClick()
        app.menuItems["Truncate Table…"].click()
        try XCTUnwrap(dialogButton("Truncate “ui_drop”"), "no Truncate in the question").click()
        expectValue("SELECT CONCAT('now=', COUNT(*)) AS v FROM ui_drop", "now=0", "Truncate left rows")
        table("ui_drop").rightClick()
        app.menuItems["Drop Table…"].click()
        try XCTUnwrap(dialogButton("Drop “ui_drop”"), "Drop didn't ask first").click()
        XCTAssertTrue(waitForGone(table("ui_drop")), "the dropped table stayed in the left panel")
    }

    func testDroppingAForeignKeyAndATriggerAskFirst() throws {
        pick(database: "sbwrite")
        run("""
            DROP TABLE IF EXISTS ui_child, ui_parent; CREATE TABLE ui_parent (id INT PRIMARY KEY) ENGINE=InnoDB;
            CREATE TABLE ui_child (id INT PRIMARY KEY, pid INT, CONSTRAINT ui_fk FOREIGN KEY (pid) REFERENCES ui_parent(id)) ENGINE=InnoDB;
            CREATE TRIGGER ui_trg BEFORE INSERT ON ui_child FOR EACH ROW SET NEW.pid = NEW.pid
            """)
        XCTAssertTrue(table("ui_child").waitForExistence(timeout: 30))
        table("ui_child").click()
        // As narrow as the window goes: the Relations pane is then narrower than the
        // table's columns on any screen, as on a 1024×768 one, and the foreign key's name
        // is scrolled to, not cut off.
        narrowWindow()

        app.typeKey("3", modifierFlags: .command)                      // Relations
        let fk = app.staticTexts["ui_fk"]
        XCTAssertTrue(fk.waitForExistence(timeout: 30), "Relations didn't list the foreign key")
        fk.click()
        element("relations.drop").click()
        try XCTUnwrap(dialogButton("Cancel"), "dropping a foreign key didn't ask first").click()
        XCTAssertTrue(fk.exists, "Cancel dropped the foreign key")
        element("relations.drop").click()
        try XCTUnwrap(dialogButton("Drop “ui_fk”"), "no Drop in the question").click()
        XCTAssertTrue(waitForGone(fk, timeout: 30), "the dropped foreign key is still listed")

        app.typeKey("4", modifierFlags: .command)                      // Triggers
        let trigger = app.staticTexts["ui_trg"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 30), "Triggers didn't list the trigger")
        trigger.click()
        element("triggers.drop").click()
        try XCTUnwrap(dialogButton("Drop “ui_trg”"), "dropping a trigger didn't ask first").click()
        XCTAssertTrue(waitForGone(trigger, timeout: 30), "the dropped trigger is still listed")
        run("DROP TABLE ui_child, ui_parent")
    }

    func testStructureAddsAColumnOnSaveAndRevertKeepsTheTable() throws {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_struct; CREATE TABLE ui_struct (id INT PRIMARY KEY)")
        XCTAssertTrue(table("ui_struct").waitForExistence(timeout: 30))
        table("ui_struct").click()
        app.typeKey("1", modifierFlags: .command)                      // Structure
        element("structure.addColumn").click()
        let name = element("structure.name.new_column")
        XCTAssertTrue(name.waitForExistence(timeout: 10), "+ added no column to name")
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("note")
        element("structure.save").click()
        expectValue("""
            SELECT CONCAT('col=', COLUMN_TYPE) AS v FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = 'sbwrite' AND TABLE_NAME = 'ui_struct' AND COLUMN_NAME = 'note'
            """, "col=varchar(255)", "Save Changes didn't add the column")

        table("ui_struct").click()
        app.typeKey("1", modifierFlags: .command)
        element("structure.addColumn").click()
        XCTAssertTrue(element("structure.name.new_column").waitForExistence(timeout: 10))
        try XCTUnwrap(dialogButton("Revert"), "no Revert for an unsaved change").click()
        expectValue("SELECT CONCAT('cols=', COUNT(*)) AS v FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = 'sbwrite' AND TABLE_NAME = 'ui_struct'",
                    "cols=2", "Revert changed the table")
        run("DROP TABLE ui_struct")
    }

    func testAQueryResultCellIsEditedInItsPopup() throws {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_pop; CREATE TABLE ui_pop (id INT PRIMARY KEY, note VARCHAR(20)); INSERT INTO ui_pop VALUES (1, 'before')")
        run("SELECT id, note FROM ui_pop")
        let cell = element("results.grid").staticTexts["before"]
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "the result didn't show the row")
        cell.doubleClick()
        let edit = app.popovers.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "double-click opened no popup with Edit")
        edit.click()
        let text = app.popovers.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10), "Edit gave nothing to type in")
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText("after")
        app.popovers.buttons["Save"].click()
        expectValue("SELECT CONCAT('note=', note) AS v FROM ui_pop WHERE id = 1", "note=after", "the popup's Save didn't write the value")
        run("DROP TABLE ui_pop")
    }

    func testCreateTableMakesTheTable() throws {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_made")
        element("sidebar.createTable").click()
        let name = app.sheets.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10), "the Create Table sheet didn't open")
        name.click()
        name.typeText("ui_made")
        app.sheets.buttons["Create Table"].click()
        XCTAssertTrue(table("ui_made").waitForExistence(timeout: 30), "the new table didn't appear in the left panel")
        expectValue("SELECT CONCAT('made=', COUNT(*)) AS v FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'sbwrite' AND TABLE_NAME = 'ui_made'",
                    "made=1", "the table wasn't made on the server")
        run("DROP TABLE ui_made")
    }

    func testCancelStopsALongQuery() {
        run("SELECT SLEEP(30)")
        let cancel = element("query.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "a running query offers no Cancel")
        let started = Date()
        cancel.click()
        XCTAssertTrue(app.buttons["query.run"].waitForExistence(timeout: 15), "the query didn't stop")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "Cancel took as long as the query")
    }

    /// A sheet's text field, by the placeholder it shows.
    func sheetField(_ placeholder: String) -> XCUIElement {
        app.sheets.firstMatch.textFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
    }

    func testAddIndexInStructureMakesTheIndex() throws {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_idx; CREATE TABLE ui_idx (id INT PRIMARY KEY, email VARCHAR(80))")
        XCTAssertTrue(table("ui_idx").waitForExistence(timeout: 30), "the new table didn't appear in the left panel")
        table("ui_idx").click()
        app.typeKey("1", modifierFlags: .command)                      // Structure
        element("structure.addIndex").click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "+ under Indexes opened no sheet")
        sheetField("e.g. idx_column").click()
        sheetField("e.g. idx_column").typeText("ui_idx_email")
        sheet.buttons.matching(NSPredicate(format: "label CONTAINS %@", "email")).firstMatch.click()
        sheet.buttons["Add Index"].click()
        XCTAssertTrue(waitForGone(sheet), "Add Index left the sheet open")
        element("structure.save").click()
        expectValue("""
            SELECT CONCAT('idx=', COUNT(*)) AS v FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = 'sbwrite' AND TABLE_NAME = 'ui_idx' AND INDEX_NAME = 'ui_idx_email' AND COLUMN_NAME = 'email'
            """, "idx=1", "Add Index, then Save Changes, made no index")
        run("DROP TABLE ui_idx")
    }

    func testAddForeignKeyInRelationsMakesTheKey() throws {
        pick(database: "sbwrite")
        run("""
            DROP TABLE IF EXISTS ui_fkc, ui_fkp; CREATE TABLE ui_fkp (id INT PRIMARY KEY) ENGINE=InnoDB;
            CREATE TABLE ui_fkc (id INT PRIMARY KEY, pid INT, KEY (pid)) ENGINE=InnoDB
            """)
        XCTAssertTrue(table("ui_fkc").waitForExistence(timeout: 30), "the new table didn't appear in the left panel")
        table("ui_fkc").click()
        app.typeKey("3", modifierFlags: .command)                      // Relations
        element("relations.add").click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "+ in Relations opened no sheet")
        // Local Column and References Table are menus of what the table and database hold.
        sheet.popUpButtons.element(boundBy: 0).click()
        app.menuItems["pid"].click()
        sheet.popUpButtons.element(boundBy: 1).click()
        app.menuItems["ui_fkp"].click()
        let column = sheetField("column_name")
        column.click()
        column.typeKey("a", modifierFlags: .command)
        column.typeText("id")
        sheetField("auto-generated if empty").click()
        sheetField("auto-generated if empty").typeText("ui_fk_made")
        sheet.buttons["Add Foreign Key"].click()
        XCTAssertTrue(waitForGone(sheet), "Add Foreign Key left the sheet open")
        XCTAssertTrue(app.staticTexts["ui_fk_made"].waitForExistence(timeout: 30), "Relations doesn't list the new key")
        expectValue("""
            SELECT CONCAT('fk=', REFERENCED_TABLE_NAME, '.', REFERENCED_COLUMN_NAME) AS v FROM information_schema.KEY_COLUMN_USAGE
            WHERE TABLE_SCHEMA = 'sbwrite' AND TABLE_NAME = 'ui_fkc' AND CONSTRAINT_NAME = 'ui_fk_made'
            """, "fk=ui_fkp.id", "the foreign key wasn't made on the server")
        run("DROP TABLE ui_fkc, ui_fkp")
    }

    func testCreateTriggerMakesATriggerThatRuns() throws {
        pick(database: "sbwrite")
        run("DROP TABLE IF EXISTS ui_trgt; CREATE TABLE ui_trgt (id INT PRIMARY KEY, note VARCHAR(20))")
        XCTAssertTrue(table("ui_trgt").waitForExistence(timeout: 30), "the new table didn't appear in the left panel")
        table("ui_trgt").click()
        app.typeKey("4", modifierFlags: .command)                      // Triggers
        element("triggers.add").click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "+ in Triggers opened no sheet")
        sheetField("e.g. before_insert_check").click()
        sheetField("e.g. before_insert_check").typeText("ui_trg_upper")
        let body = sheet.textViews.firstMatch
        body.click()
        body.typeKey("a", modifierFlags: .command)
        body.typeText("BEGIN\n  SET NEW.note = UPPER(NEW.note);\nEND")          // as the sheet's own template has it
        sheet.buttons["Create Trigger"].click()
        XCTAssertTrue(waitForGone(sheet), "Create Trigger left the sheet open")
        XCTAssertTrue(app.staticTexts["ui_trg_upper"].waitForExistence(timeout: 30), "Triggers doesn't list the new trigger")
        run("INSERT INTO ui_trgt VALUES (1, 'quiet')")
        expectValue("SELECT CONCAT('note=', note) AS v FROM ui_trgt", "note=QUIET", "the new trigger didn't run")
        run("DROP TABLE ui_trgt")
    }

    /// A script on one connection that failed before its USE still moved the left panel to
    /// the database it named, which it never reached.
    func testAScriptThatFailsBeforeItsUSELeavesTheDatabasePicked() {
        run("SET @n = 1; SELEC 2; USE sbwrite")
        XCTAssertTrue(text(containing: "Statement 2 of 3").waitForExistence(timeout: 30), "the script's failure wasn't shown")
        let moved = expectation(for: NSPredicate(format: "value == %@", "sbwrite"), evaluatedWith: element("sidebar.database"))
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .timedOut, "the left panel moved to a database the script never reached")
        XCTAssertEqual(element("sidebar.database").value as? String, "sbtest")
    }
}

/// The same flows through a Unix socket (a relay to the same MariaDB). Needs SB_UI_MYSQL_SOCKET.
final class MySQLActionsOverSocketUITests: MySQLActionsUITests {
    override func connectionEntry(port: Int) throws -> [String: Any] {
        guard let socket = env["SB_UI_MYSQL_SOCKET"] else { throw XCTSkip("no MySQL socket for the UI tests (SB_UI_MYSQL_SOCKET)") }
        var entry = try super.connectionEntry(port: port)
        entry["id"] = "5B0A0000-0000-4000-8000-000000000603"
        entry["connectionType"] = "Socket"
        entry["socketPath"] = socket
        return entry
    }
}

/// The same flows through an SSH tunnel to the same MariaDB (the test SSH server sees it at
/// host.docker.internal). Needs SB_UI_SSH_KEY.
final class MySQLActionsOverSSHUITests: MySQLActionsUITests {
    override func connectionEntry(port: Int) throws -> [String: Any] {
        guard let key = env["SB_UI_SSH_KEY"] else { throw XCTSkip("no SSH server for the UI tests (SB_UI_SSH_KEY)") }
        var entry = try super.connectionEntry(port: Int(env["SB_UI_SSH_DB_PORT"] ?? "") ?? port)
        entry["id"] = "5B0A0000-0000-4000-8000-000000000602"
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
