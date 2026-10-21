//
//  WorkspaceServersUITests.swift
//  SequelBridgeUITests
//
//  Adding a server to an open workspace with its + button: Connect on one saved
//  connection opens that one; New Connection… then Cancel opens nothing. Closing that
//  sheet used to connect every saved favorite not yet open, Cancel included. Two SQLite
//  files, so no server is needed.
//

import XCTest

final class WorkspaceServersUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-servers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeSQLite("a.sqlite", table: "alpha_items")
        try makeSQLite("b.sqlite", table: "beta_items")
        let fixture = dir.appendingPathComponent("connections.json")
        try """
        [
          {"id":"5B0A0000-0003-4000-8000-000000000001","name":"Lite A","alias":"litea","connectionType":"TCP/IP","color":"#3A9AA8",
           "host":"","port":0,"username":"","database":"\(dir.path)/a.sqlite","engine":"sqlite","folder":"","readOnly":false},
          {"id":"5B0A0000-0003-4000-8000-000000000002","name":"Lite B","alias":"liteb","connectionType":"TCP/IP","color":"#D97A0B",
           "host":"","port":0,"username":"","database":"\(dir.path)/b.sqlite","engine":"sqlite","folder":"","readOnly":false}
        ]
        """.write(to: fixture, atomically: true, encoding: .utf8)
        let support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchArguments = ["-SBConnectionsFile", fixture.path, "-SBSupportDir", support.path,
                               "-ApplePersistenceIgnoreState", "YES", "-theme", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["home.select.litea"].waitForExistence(timeout: 30), "Home didn't show the connections")
        app.buttons["home.select.litea"].click()            // only A
        app.buttons["home.connect"].click()
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 120), "the workspace didn't open")
        XCTAssertTrue(tab("litea").waitForExistence(timeout: 30))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeSQLite(_ name: String, table: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [dir.appendingPathComponent(name).path, "CREATE TABLE \(table) (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO \(table) (name) VALUES ('x');"]
        try p.run(); p.waitUntilExit()
    }

    private func tab(_ alias: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar.connection.\(alias)").firstMatch
    }

    func testCancellingANewConnectionOpensNoOtherServer() {
        app.buttons["sidebar.addConnection"].click()
        let newConnection = app.sheets.buttons["New Connection…"]
        XCTAssertTrue(newConnection.waitForExistence(timeout: 10), "the + didn't offer New Connection…")
        newConnection.click()
        XCTAssertTrue(app.staticTexts["New Connection"].waitForExistence(timeout: 10), "the New Connection sheet didn't open")
        app.windows.buttons["Cancel"].firstMatch.click()   // the sheet's, not the Touch Bar's
        XCTAssertFalse(tab("liteb").waitForExistence(timeout: 8), "cancelling a new connection opened a saved one")
    }

    func testConnectInTheAddServerSheetOpensThatServer() {
        app.buttons["sidebar.addConnection"].click()
        let connect = app.sheets.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "the + listed no saved connection to add")
        connect.click()
        XCTAssertTrue(tab("liteb").waitForExistence(timeout: 30), "Connect didn't open the server")
    }
}
