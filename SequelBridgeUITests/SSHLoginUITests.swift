//
//  SSHLoginUITests.swift
//  SequelBridgeUITests
//
//  What an SSH server asks while logging in, answered in the app's dialog as a person
//  would: typed straight in, without clicking the field first. A one-time code from an
//  authenticator app (otpuser, on the old-style server) and a password (pwuser), on the
//  test SSH server (scripts/fixtures/ssh/sshd-setup.sh). The dialog once showed no field
//  to type a code in. Each launch gets a known-hosts file of its own. With no
//  SB_UI_SSH_KEY the suite is skipped.
//

import CryptoKit
import XCTest

final class SSHLoginUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!
    private let alias = "sshlogin"

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SB_UI_SSH_KEY"] != nil else { throw XCTSkip("no SSH server for the UI tests (SB_UI_SSH_KEY)") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ui-sshlogin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Quit as a person does, so the app ends its ssh tunnels; terminate() kills it and
        // leaves them running.
        if let app, app.state != .notRunning {
            app.typeKey("q", modifierFlags: .command)
            if !app.wait(for: .notRunning, timeout: 15) { app.terminate() }
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Helpers

    /// Starts the app with one SSH connection for `user` and connects. The test key is set,
    /// and it isn't theirs, so the server asks; the Mac's own keys are never offered.
    private func connect(as user: String, sshPort: Int) throws {
        let fixture = dir.appendingPathComponent("connections.json")
        let entry: [String: Any] = [
            "id": "5B0A0000-0000-4000-8000-000000000501", "name": "SSH login", "alias": alias,
            "connectionType": "SSH", "color": "#6A8D4E",
            "host": env["SB_UI_SSH_DB_HOST"] ?? "host.docker.internal", "port": Int(env["SB_UI_SSH_DB_PORT"] ?? "") ?? 3309,
            "username": env["SB_UI_SSH_DB_USER"] ?? "root", "password": env["SB_UI_SSH_DB_PASS"] ?? "",
            "database": "sbtest", "engine": "mysql", "folder": "", "readOnly": false,
            "sshHost": "127.0.0.1", "sshPort": sshPort, "sshUsername": user, "sshKeyPath": env["SB_UI_SSH_KEY"] ?? "",
        ]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: fixture)
        let support = dir.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let knownHosts = dir.appendingPathComponent("known_hosts")
        try "".write(to: knownHosts, atomically: true, encoding: .utf8)

        app = XCUIApplication()
        app.launchArguments = ["-SBConnectionsFile", fixture.path, "-SBSupportDir", support.path,
                               "-SBKnownHostsFile", knownHosts.path,
                               "-ApplePersistenceIgnoreState", "YES", "-theme", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["home.select.\(alias)"].waitForExistence(timeout: 30), "Home didn't show the connection")
        app.buttons["home.select.\(alias)"].click()
        app.buttons["home.connect"].click()
        // Met for the first time: trusted (SSHHostKeyUITests covers that question).
        try XCTUnwrap(dialogButton("Trust and Connect"), "no question about the new server").click()
    }

    private func text(containing s: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", s)).firstMatch
    }

    /// A button of the alert on screen, not the Touch Bar's copy of it.
    private func dialogButton(_ title: String, timeout: TimeInterval = 30) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for b in [app.dialogs.buttons[title], app.windows.buttons[title]] where b.exists { return b }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    /// The login dialog's field, checked to be there and wide enough to type in.
    private func loginField(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let field = app.dialogs.secureTextFields.firstMatch
        XCTAssertTrue(field.exists, "the dialog has no field", file: file, line: line)
        XCTAssertGreaterThanOrEqual(field.frame.width, 200, "the field is too narrow to type in", file: file, line: line)
        return field
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.dialogs.firstMatch.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// The code an authenticator app shows now for otpuser's secret (base32 JBSWY3DPEHPK3PXP;
    /// RFC 6238: HMAC-SHA1, 30-second steps, 6 digits).
    private static func totp(at date: Date = Date()) -> String {
        let secret = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x21, 0xDE, 0xAD, 0xBE, 0xEF])
        let counter = withUnsafeBytes(of: UInt64(date.timeIntervalSince1970 / 30).bigEndian) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: counter, using: SymmetricKey(data: secret)))
        let o = Int(mac[19] & 0x0F)
        let value = (UInt32(mac[o] & 0x7F) << 24 | UInt32(mac[o + 1]) << 16 | UInt32(mac[o + 2]) << 8 | UInt32(mac[o + 3])) % 1_000_000
        return String(format: "%06u", value)
    }

    // MARK: - Flows

    func testAOneTimeCodeIsTypedIntoTheDialog() throws {
        try connect(as: "otpuser", sshPort: Int(env["SB_UI_SSH_LEGACY_PORT"] ?? "") ?? 2225)
        let logIn = try XCTUnwrap(dialogButton("Log In"), "no login dialog")
        XCTAssertTrue(text(containing: "Verification code").exists, "the dialog didn't show the server's question")
        _ = loginField()
        XCTAssertFalse(app.dialogs.checkBoxes["Remember in Keychain"].exists, "a one-time code offered to be saved")
        app.typeText(Self.totp())                       // straight in: the field has the focus
        shot("typed")
        logIn.click()
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 180), "the code didn't log in")
    }

    func testAPasswordIsTypedIntoTheDialog() throws {
        try connect(as: "pwuser", sshPort: Int(env["SB_UI_SSH_PORT"] ?? "") ?? 2224)
        let logIn = try XCTUnwrap(dialogButton("Log In"), "no login dialog")
        XCTAssertTrue(text(containing: "password").exists, "the dialog didn't show the server's question")
        _ = loginField()
        XCTAssertTrue(app.dialogs.checkBoxes["Remember in Keychain"].exists, "no offer to keep the password")
        app.typeText("sbssh123")                        // straight in: the field has the focus
        shot("typed")
        logIn.click()
        XCTAssertTrue(app.buttons["query.newTab"].waitForExistence(timeout: 180), "the password didn't log in")
    }
}
