//
//  ClickHouseWorkflowUITests.swift
//  SequelBridgeUITests
//
//  ClickHouse clicked through the app on a real server: its tables, Content's rows and
//  why a cell can't be edited there, a query, and the Server tab's query insights. With
//  no SB_UI_CH_PORT the suite is skipped.
//

import XCTest

final class ClickHouseWorkflowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!
    private let alias = "ch"

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let port = env["SB_UI_CH_PORT"] else { throw XCTSkip("no ClickHouse for the UI tests (SB_UI_CH_PORT)") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-ch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = dir.appendingPathComponent("connections.json")
        let entry: [String: Any] = [
            "id": "5B0A0000-0000-4000-8000-000000000301", "name": "ClickHouse", "alias": alias,
            "connectionType": "TCP/IP", "color": "#C9A227",
            "host": env["SB_UI_CH_HOST"] ?? "127.0.0.1", "port": Int(port) ?? 8123,
            "username": env["SB_UI_CH_USER"] ?? "sbuser", "password": env["SB_UI_CH_PASS"] ?? "",
            "database": "default", "engine": "clickhouse", "folder": "", "readOnly": false,
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
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 120), "the workspace didn't open")
        XCTAssertTrue(table("events").waitForExistence(timeout: 60), "default's tables weren't listed")
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

    private func run(_ sql: String) {
        app.typeKey("6", modifierFlags: .command)
        let editor = element("query.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no SQL editor")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(sql)
        app.buttons["query.run"].click()
    }

    // MARK: - Flows

    func testContentShowsTheRowsAndSaysWhyACellCantBeEdited() {
        table("events").click()
        app.typeKey("2", modifierFlags: .command)
        let cell = element("results.grid").staticTexts["N002SB"]
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "Content didn't show the rows")
        cell.doubleClick()
        XCTAssertTrue(text(containing: "ALTER TABLE").waitForExistence(timeout: 10), "a cell didn't say why it can't be edited")
    }

    func testAQueryRunsAndTheServerTabShowsInsights() {
        run("SELECT tail, value FROM events ORDER BY id DESC")
        XCTAssertTrue(element("results.grid").staticTexts["N003SB"].waitForExistence(timeout: 30), "the query's rows didn't show")
        app.typeKey("8", modifierFlags: .command)
        let refresh = element("server.refresh")
        XCTAssertTrue(refresh.waitForExistence(timeout: 30), "no Server tab")
        // ClickHouse writes its query log every few seconds.
        var listed = false
        for _ in 0..<8 where !listed {
            listed = text(containing: "SELECT tail, value FROM events").waitForExistence(timeout: 5)
            if !listed { refresh.click() }
        }
        XCTAssertTrue(listed, "the Server tab's insights didn't list the query")
    }
}
