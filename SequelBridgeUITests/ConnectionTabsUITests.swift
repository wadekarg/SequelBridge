//
//  ConnectionTabsUITests.swift
//  SequelBridgeUITests
//
//  The connection tabs at the top of the left panel sat in one strip that scrolled
//  sideways, so with several servers open some slid out of sight. They wrap onto more
//  rows now: with six servers connected, every tab and the + are on screen and take a
//  click. Six SQLite files in a temporary folder stand in for servers.
//

import XCTest

final class ConnectionTabsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!
    private let aliases = ["orders_east", "orders_west", "billing", "inventory", "analytics", "archive"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var entries: [String] = []
        for (i, alias) in aliases.enumerated() {
            let file = dir.appendingPathComponent("\(alias).sqlite")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            p.arguments = [file.path, "CREATE TABLE \(alias)_items (id INTEGER PRIMARY KEY);"]
            try p.run()
            p.waitUntilExit()
            entries.append("""
              {"id":"5B0A0000-0000-4000-8000-00000000001\(i)","name":"\(alias)","alias":"\(alias)","connectionType":"TCP/IP",
               "color":"#3A9AA8","host":"","port":0,"username":"","database":"\(file.path)","engine":"sqlite","folder":"","readOnly":false}
            """)
        }
        let fixture = dir.appendingPathComponent("connections.json")
        try "[\n\(entries.joined(separator: ",\n"))\n]".write(to: fixture, atomically: true, encoding: .utf8)
        let support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchArguments = ["-SBConnectionsFile", fixture.path, "-SBSupportDir", support.path,
                               "-ApplePersistenceIgnoreState", "YES", "-theme", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["home.select.\(aliases[0])"].waitForExistence(timeout: 30), "Home didn't show the connections")
        for alias in aliases { app.buttons["home.select.\(alias)"].click() }
        app.buttons["home.connect"].click()
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 120), "the workspace didn't open")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testEveryConnectionTabIsOnScreen() {
        for alias in aliases {
            let tab = element("sidebar.connection.\(alias)")
            XCTAssertTrue(tab.waitForExistence(timeout: 30), "no tab for \(alias)")
            XCTAssertTrue(tab.isHittable, "the \(alias) tab is out of sight")
        }
        XCTAssertTrue(app.buttons["sidebar.addConnection"].isHittable, "the + is out of sight")
        let last = element("sidebar.connection.\(aliases.last!)")
        last.click()
        XCTAssertTrue(last.isSelected, "clicking the last tab didn't select it")
    }

    func testTheStripStaysTidy() {
        // The + sits at the top right of the left panel, right above the database menu's ….
        let plus = app.buttons["sidebar.addConnection"]
        let menu = element("sidebar.databaseMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "no database menu")
        XCTAssertEqual(plus.frame.midX, menu.frame.midX, accuracy: 3, "the + isn't above the …")
        XCTAssertLessThanOrEqual(plus.frame.maxY, menu.frame.minY + 1, "the + isn't above the …")
        // Every engine badge stays on one line, whatever the alias beside it.
        for alias in aliases {
            let badge = element("sidebar.connection.\(alias)").descendants(matching: .any)
                .matching(identifier: "engine.badge").firstMatch
            XCTAssertTrue(badge.waitForExistence(timeout: 10), "no engine badge on \(alias)")
            XCTAssertLessThan(badge.frame.height, 20, "\(alias)'s badge wrapped onto more lines")
        }
    }
}
