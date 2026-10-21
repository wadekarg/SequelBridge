//
//  ClickHouseWorkflowUITests.swift
//  SequelBridgeUITests
//
//  ClickHouse clicked through the app on a real server: its tables, Content's rows and
//  why a cell can't be edited there, a query, and the Server tab's query insights.
//  ClickHouseWorkflowOverSSHUITests runs them again through an SSH tunnel. With no
//  SB_UI_CH_PORT the suite is skipped.
//

import XCTest

class ClickHouseWorkflowUITests: XCTestCase {
    var app: XCUIApplication!
    private var dir: URL!
    let alias = "ch"

    var env: [String: String] { ProcessInfo.processInfo.environment }

    /// The connection to make: TCP/IP here; the subclass goes through SSH.
    func connectionEntry(port: Int) throws -> [String: Any] {
        [
            "id": "5B0A0000-0000-4000-8000-000000000301", "name": "ClickHouse", "alias": alias,
            "connectionType": "TCP/IP", "color": "#C9A227",
            "host": env["SB_UI_CH_HOST"] ?? "127.0.0.1", "port": port,
            "username": env["SB_UI_CH_USER"] ?? "sbuser", "password": env["SB_UI_CH_PASS"] ?? "",
            "database": "default", "engine": "clickhouse", "folder": "", "readOnly": false,
        ]
    }

    /// Extra launch arguments (through SSH, a known-hosts file of its own).
    func launchArguments(in dir: URL) throws -> [String] { [] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let port = env["SB_UI_CH_PORT"] else { throw XCTSkip("no ClickHouse for the UI tests (SB_UI_CH_PORT)") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-ch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = dir.appendingPathComponent("connections.json")
        try JSONSerialization.data(withJSONObject: [try connectionEntry(port: Int(port) ?? 8123)]).write(to: fixture)
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
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 120), "the workspace didn't open")
        XCTAssertTrue(table("events").waitForExistence(timeout: 60), "default's tables weren't listed")
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

    /// A button of the question on screen (a sheet over the window), not the Touch Bar's copy.
    private func dialogButton(_ title: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for b in [app.sheets.buttons[title], app.dialogs.buttons[title], app.windows.buttons[title]] where b.exists { return b }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return nil
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

/// The same flows through an SSH tunnel to the same ClickHouse (the test SSH server sees it
/// at host.docker.internal). Needs SB_UI_SSH_KEY.
final class ClickHouseWorkflowOverSSHUITests: ClickHouseWorkflowUITests {
    override func connectionEntry(port: Int) throws -> [String: Any] {
        guard let key = env["SB_UI_SSH_KEY"] else { throw XCTSkip("no SSH server for the UI tests (SB_UI_SSH_KEY)") }
        var entry = try super.connectionEntry(port: port)
        entry["id"] = "5B0A0000-0000-4000-8000-000000000302"
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
