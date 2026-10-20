//
//  VisualTourUITests.swift
//  SequelBridgeUITests
//
//  A screenshot of every screen and sheet, in light and in dark mode, kept in the test
//  results for a person to look over: layout that wraps, clips, overlaps or misaligns
//  shows here first. Only the app's own window is captured. Runs against the MariaDB of
//  the other MySQL UI tests, beside two SQLite files, one under a long alias; skipped
//  without SB_UI_MYSQL_PORT.
//
//  The images: xcrun xcresulttool export attachments --path <result bundle> --output-path <dir>
//

import XCTest

final class VisualTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func launch(theme: String) throws {
        continueAfterFailure = true
        guard let port = env["SB_UI_MYSQL_PORT"] else { throw XCTSkip("no MariaDB for the UI tests (SB_UI_MYSQL_PORT)") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-tour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (file, table) in [("lite.sqlite", "notes"), ("warehouse.sqlite", "shipments")] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            p.arguments = [dir.appendingPathComponent(file).path,
                           "CREATE TABLE \(table) (id INTEGER PRIMARY KEY, body TEXT); INSERT INTO \(table) VALUES (1, 'first');"]
            try p.run(); p.waitUntilExit()
        }
        func sqlite(_ n: Int, _ alias: String, _ file: String) -> [String: Any] {
            ["id": "5B0A0000-0000-4000-8000-00000000030\(n)", "name": alias, "alias": alias, "connectionType": "TCP/IP",
             "color": n == 2 ? "#D97A0B" : "#7A5CD9", "host": "", "port": 0, "username": "",
             "database": dir.appendingPathComponent(file).path, "engine": "sqlite", "folder": "", "readOnly": false]
        }
        let shop: [String: Any] = [
            "id": "5B0A0000-0000-4000-8000-000000000301", "name": "Shop", "alias": "shop", "connectionType": "TCP/IP",
            "color": "#3A9AA8", "host": env["SB_UI_MYSQL_HOST"] ?? "127.0.0.1", "port": Int(port) ?? 3306,
            "username": env["SB_UI_MYSQL_USER"] ?? "sbui", "password": env["SB_UI_MYSQL_PASS"] ?? "",
            "database": "sbtest", "engine": "mysql", "folder": "", "readOnly": false]
        let fixture = dir.appendingPathComponent("connections.json")
        try JSONSerialization.data(withJSONObject: [shop, sqlite(2, "lite", "lite.sqlite"),
                                                    sqlite(3, "analytics_warehouse", "warehouse.sqlite")]).write(to: fixture)
        let support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-SBConnectionsFile", fixture.path, "-SBSupportDir", support.path,
                               "-ApplePersistenceIgnoreState", "YES", "-theme", theme]
        app.launch()
        XCTAssertTrue(app.buttons["home.select.shop"].waitForExistence(timeout: 30))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func shoot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tour(_ theme: String) throws {
        try launch(theme: theme)
        let t = theme.lowercased()
        shoot("\(t)-01-home")
        for alias in ["shop", "lite", "analytics_warehouse"] { app.buttons["home.select.\(alias)"].click() }
        app.buttons["home.connect"].click()
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 180))
        element("sidebar.connection.shop").click()
        XCTAssertTrue(element("sidebar.table.orders").waitForExistence(timeout: 60))
        shoot("\(t)-02-workspace")

        let editor = element("query.editor")
        app.typeKey("6", modifierFlags: .command)
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("SELECT * FROM orders ORDER BY id LIMIT 50")
        app.buttons["query.run"].click()
        _ = element("results.grid").waitForExistence(timeout: 30)
        sleep(2)
        shoot("\(t)-03-query-result")

        element("sidebar.table.orders").click()
        let tabs: [(String, String)] = [("1", "structure"), ("2", "content"), ("3", "relations"), ("4", "triggers"),
                                        ("5", "table-info"), ("7", "routines"), ("8", "server"), ("9", "console")]
        for (n, (key, name)) in tabs.enumerated() {
            app.typeKey(key, modifierFlags: .command)
            sleep(3)
            shoot("\(t)-\(String(format: "%02d", n + 4))-\(name)")
        }

        app.typeKey("2", modifierFlags: .command)
        sleep(2)
        app.typeKey("j", modifierFlags: .command)
        sleep(1)
        shoot("\(t)-11a-page-options")
        app.typeKey(.escape, modifierFlags: [])
        element("content.addRow").click()
        sleep(1)
        shoot("\(t)-11b-add-row-sheet")
        app.typeKey(.escape, modifierFlags: [])

        element("sidebar.table.orders").rightClick()
        if app.menuItems["Rename Table…"].waitForExistence(timeout: 5) {
            app.menuItems["Rename Table…"].click()
            sleep(1)
            shoot("\(t)-12-rename-sheet")
            app.typeKey(.escape, modifierFlags: [])
        }
        element("sidebar.createTable").click()
        sleep(2)
        shoot("\(t)-13-create-table-sheet")
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["sidebar.addConnection"].click()
        sleep(2)
        shoot("\(t)-14-add-connection-sheet")
        app.typeKey(.escape, modifierFlags: [])

        element("sidebar.connection.analytics_warehouse").click()
        sleep(3)
        shoot("\(t)-15-sqlite-workspace")
    }

    func testTourLight() throws { try tour("Light") }
    func testTourDark() throws { try tour("Dark") }
}
