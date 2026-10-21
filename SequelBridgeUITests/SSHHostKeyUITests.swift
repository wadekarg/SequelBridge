//
//  SSHHostKeyUITests.swift
//  SequelBridgeUITests
//
//  An SSH server's key, clicked through the app against the test SSH server
//  (scripts/fixtures/ssh/sshd-setup.sh): a server met for the first time asks to be
//  trusted and shows its key's fingerprint; a server whose key changed says so, and
//  "Forget the Old Key…" asks first. Each launch gets a known-hosts file of its own
//  (-SBKnownHostsFile), never the Mac's. With no SB_UI_SSH_KEY the suite is skipped.
//

import XCTest

final class SSHHostKeyUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!
    private var fixture: URL!
    private var support: URL!
    private var knownHosts: URL!
    private let alias = "viassh"

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    /// ssh names a server on a port other than 22 this way in known_hosts.
    private var server: String { "[127.0.0.1]:\(env["SB_UI_SSH_PORT"] ?? "2224")" }
    /// A key of the test server's type (ED25519) that isn't the server's: its private half is gone.
    private let otherKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKToTXsiUhm+reO/F7K4kjPhrvvZHVioYQHQ7ndYICTz"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let key = env["SB_UI_SSH_KEY"] else { throw XCTSkip("no SSH server for the UI tests (SB_UI_SSH_KEY)") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fixture = dir.appendingPathComponent("connections.json")
        // The MariaDB container as the SSH server sees it.
        let entry: [String: Any] = [
            "id": "5B0A0000-0000-4000-8000-000000000401", "name": "Through SSH", "alias": alias,
            "connectionType": "SSH", "color": "#6A8D4E",
            "host": env["SB_UI_SSH_DB_HOST"] ?? "host.docker.internal", "port": Int(env["SB_UI_SSH_DB_PORT"] ?? "") ?? 3309,
            "username": env["SB_UI_SSH_DB_USER"] ?? "root", "password": env["SB_UI_SSH_DB_PASS"] ?? "",
            "database": "sbtest", "engine": "mysql", "folder": "", "readOnly": false,
            "sshHost": "127.0.0.1", "sshPort": Int(env["SB_UI_SSH_PORT"] ?? "") ?? 2224,
            "sshUsername": "tunneluser", "sshKeyPath": key,
        ]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: fixture)
        support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        knownHosts = dir.appendingPathComponent("known_hosts")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Helpers

    /// Starts the app with `remembered` as everything it knows about servers' keys.
    private func launch(remembering remembered: String) throws {
        try remembered.write(to: knownHosts, atomically: true, encoding: .utf8)
        app = XCUIApplication()
        app.launchArguments = ["-SBConnectionsFile", fixture.path, "-SBSupportDir", support.path,
                               "-SBKnownHostsFile", knownHosts.path,
                               "-ApplePersistenceIgnoreState", "YES", "-theme", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["home.select.\(alias)"].waitForExistence(timeout: 30), "Home didn't show the connection")
    }

    private var remembered: String { (try? String(contentsOf: knownHosts, encoding: .utf8)) ?? "" }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func text(containing s: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", s)).firstMatch
    }

    /// A button of the alert or sheet on screen, not the Touch Bar's copy of it.
    private func dialogButton(_ title: String, timeout: TimeInterval = 30) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for b in [app.dialogs.buttons[title], app.windows.buttons[title]] where b.exists { return b }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    private func connectFromHome() {
        app.buttons["home.select.\(alias)"].click()
        app.buttons["home.connect"].click()
    }

    // MARK: - Flows

    func testANewServerShowsItsFingerprintAndIsRememberedOnlyWhenTrusted() throws {
        try launch(remembering: "")
        connectFromHome()
        let cancel = try XCTUnwrap(dialogButton("Cancel"), "no question about the new server")
        XCTAssertTrue(text(containing: "SHA256:").exists, "the question didn't show the key's fingerprint")
        cancel.click()
        XCTAssertTrue(text(containing: "wasn't trusted").waitForExistence(timeout: 30), "declining didn't say why it stopped")
        XCTAssertEqual(remembered, "", "a server not trusted was remembered")

        app.buttons["home.connect"].click()
        try XCTUnwrap(dialogButton("Trust and Connect"), "no question about the new server").click()
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 180), "the workspace didn't open")
        XCTAssertTrue(remembered.contains(server), "the trusted key wasn't remembered: \(remembered)")
    }

    func testAChangedKeyIsSaidPlainlyAndTheOldOneForgottenOnlyWhenConfirmed() throws {
        try launch(remembering: "\(server) \(otherKey)\n")
        connectFromHome()
        let forget = app.buttons["home.forgetHostKey"]
        XCTAssertTrue(forget.waitForExistence(timeout: 60), "no way offered past the changed key")
        XCTAssertTrue(text(containing: "SSH key has changed").exists, "the changed key wasn't said plainly")

        forget.click()
        XCTAssertTrue(text(containing: "Forget the old key for").waitForExistence(timeout: 10), "forgetting didn't ask first")
        try XCTUnwrap(dialogButton("Cancel")).click()
        XCTAssertTrue(remembered.contains(otherKey), "the old key went without a yes")

        forget.click()
        try XCTUnwrap(dialogButton("Forget Old Key"), "no confirmation").click()
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 180), "didn't connect with the old key forgotten")
        XCTAssertFalse(remembered.contains(otherKey), "the old key is still remembered")
        XCTAssertTrue(remembered.contains(server), "the new key wasn't remembered: \(remembered)")
    }

    func testTestConnectionOffersToForgetAChangedKey() throws {
        try launch(remembering: "\(server) \(otherKey)\n")
        app.staticTexts["Through SSH"].click()                          // opens the connection's sheet
        let test = try XCTUnwrap(dialogButton("Test Connection"), "the connection's sheet didn't open")
        XCTAssertFalse(text(containing: "Key-based auth only").exists, "the sheet says SSH needs a key")
        // The sheet reads the password from the Keychain, which a fixture doesn't use.
        let password = app.windows.secureTextFields.firstMatch
        password.click()
        password.typeText(env["SB_UI_SSH_DB_PASS"] ?? "")
        test.click()
        let forget = element("connection.forgetHostKey")
        XCTAssertTrue(forget.waitForExistence(timeout: 60), "no way offered past the changed key")
        XCTAssertTrue(text(containing: "SSH key has changed").exists, "the changed key wasn't said plainly")
        forget.click()
        try XCTUnwrap(dialogButton("Forget Old Key"), "no confirmation").click()
        XCTAssertTrue(text(containing: "Connection successful").waitForExistence(timeout: 180), "the test didn't pass after forgetting")
        XCTAssertFalse(remembered.contains(otherKey), "the old key is still remembered")
    }
}
