//
//  SSHAskpassHelperTests.swift
//  SequelBridgeTests
//
//  ssh asks its questions through an askpass program. The app wrote it to a temporary
//  folder at each login; the sandbox won't run a file the app wrote, so it ships inside the
//  app, for both builds.
//

import Foundation
import Testing
@testable import SequelBridge

@MainActor
@Suite("The askpass helper inside the app")
struct SSHAskpassHelperTests {
    @Test("it is in the app, executable, and nothing is written at run time")
    func shipped() async throws {
        let url = try #require(SSHAskpass.helperURL, "no sb-askpass in the app")
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        #expect(url.path.hasPrefix(Bundle.main.bundlePath))
        let askpass = try await SSHAskpass { _ in "x" }
        defer { askpass.stop() }
        #expect(askpass.scriptURL == url)
        #expect(askpass.environment["SSH_ASKPASS"] == url.path)
    }

    @Test("run as ssh runs it, it asks the app the question and prints the app's answer")
    func answers() async throws {
        let askpass = try await SSHAskpass { prompt in prompt == "Password for me:" ? "s3cret" : nil }
        defer { askpass.stop() }
        let p = Process()
        p.executableURL = askpass.scriptURL
        p.arguments = ["Password for me:"]
        p.environment = askpass.environment
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        // The app answers on the main actor: let it run while the helper waits.
        while p.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0 && text == "s3cret\n", "\(p.terminationStatus) \(text)")
    }
}
