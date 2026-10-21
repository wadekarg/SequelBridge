//
//  HomeConnectionSheetUITests.swift
//  SequelBridgeUITests
//
//  The connection sheet from Home, the first thing a new user meets: New Connection adds
//  a favorite and Cancel adds none; a click on a row edits it, Save Changes keeps the
//  edit, and its Connect opens the workspace. On SQLite files, so no server is needed, in
//  a support folder of the test's own (the list is saved there; a SQLite file has no
//  password, so nothing reaches the Keychain).
//

import XCTest

final class HomeConnectionSheetUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!
    private var list: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-sheet-\(UUID().uuidString)")
        let support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for name in ["a", "b"] {
            try sqlite(dir.appendingPathComponent("\(name).sqlite").path,
                       "CREATE TABLE notes_\(name) (id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes_\(name) (body) VALUES ('hello')")
        }
        list = support.appendingPathComponent("connections.json")
        try """
        [
          {"id":"5B0A0000-0005-4000-8000-000000000001","name":"Lite A","alias":"litea","connectionType":"TCP/IP","color":"#3A9AA8",
           "host":"","port":0,"username":"","database":"\(dir.path)/a.sqlite","engine":"sqlite","folder":"","readOnly":false}
        ]
        """.write(to: list, atomically: true, encoding: .utf8)
        app = XCUIApplication()
        app.launchArguments = ["-SBSupportDir", support.path, "-ApplePersistenceIgnoreState", "YES", "-theme", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["home.select.litea"].waitForExistence(timeout: 30), "Home didn't show the saved connection")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Helpers

    private func sqlite(_ file: String, _ sql: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [file, sql]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "sqlite3 couldn't make \(file)")
    }

    private var sheet: XCUIElement { app.sheets.firstMatch }

    /// One of the sheet's text fields, by the placeholder it shows.
    private func field(_ placeholder: String) -> XCUIElement {
        sheet.textFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
    }

    /// Replaces what a field holds with `text`.
    private func type(_ text: String, into placeholder: String) {
        let f = field(placeholder)
        XCTAssertTrue(f.waitForExistence(timeout: 10), "no field “\(placeholder)” in the sheet")
        f.click()
        f.typeKey("a", modifierFlags: .command)
        f.typeText(text)
    }

    /// A segment of one of the sheet's pickers (Database, Connection Type).
    private func choose(_ title: String) {
        for option in [sheet.radioButtons[title], sheet.buttons[title]] where option.waitForExistence(timeout: 3) {
            option.click()
            return
        }
        XCTFail("no “\(title)” to pick in the sheet")
    }

    private func waitForGone(_ e: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private var saved: String { (try? String(contentsOf: list, encoding: .utf8)) ?? "" }

    // MARK: - Flows

    func testNewConnectionIsAddedToFavorites() {
        app.buttons["New Connection"].click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "New Connection opened no sheet")
        choose("SQLite")
        type("Lite B", into: "e.g. Production DB")
        type("liteb", into: "e.g. db12")
        type("\(dir.path)/b.sqlite", into: "~/data/app.sqlite")
        sheet.buttons["Add to Favorites"].click()
        XCTAssertTrue(waitForGone(sheet), "Add to Favorites left the sheet open")
        XCTAssertTrue(app.buttons["home.select.liteb"].waitForExistence(timeout: 10), "the new connection isn't listed")
        XCTAssertTrue(saved.contains("\"liteb\""), "the new connection wasn't saved")
        XCTAssertTrue(app.buttons["home.select.litea"].exists, "the other connection went")
    }

    func testCancelAddsNoConnection() {
        app.buttons["New Connection"].click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "New Connection opened no sheet")
        choose("SQLite")
        type("Not This", into: "e.g. Production DB")
        type("notthis", into: "e.g. db12")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitForGone(sheet), "Cancel left the sheet open")
        XCTAssertFalse(app.buttons["home.select.notthis"].exists, "Cancel added the connection")
        XCTAssertFalse(saved.contains("notthis"), "Cancel saved the connection")
    }

    func testEditingAConnectionKeepsTheChange() {
        app.staticTexts["Lite A"].click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "a click on the row opened no sheet")
        type("Lite A Renamed", into: "e.g. Production DB")
        sheet.buttons["Save Changes"].click()
        XCTAssertTrue(waitForGone(sheet), "Save Changes left the sheet open")
        XCTAssertTrue(app.staticTexts["Lite A Renamed"].waitForExistence(timeout: 10), "the new name isn't listed")
        XCTAssertTrue(saved.contains("Lite A Renamed"), "the change wasn't saved")
    }

    func testConnectFromTheSheetOpensTheWorkspace() {
        app.staticTexts["Lite A"].click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "a click on the row opened no sheet")
        sheet.buttons["Connect"].click()
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 60), "Connect didn't open the workspace")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sidebar.table.notes_a").firstMatch
                        .waitForExistence(timeout: 30), "the file's table isn't listed")
    }
}
