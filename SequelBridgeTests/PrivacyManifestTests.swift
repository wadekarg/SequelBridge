//
//  PrivacyManifestTests.swift
//  SequelBridgeTests
//
//  The privacy manifest Apple requires: no tracking, no data collected, and the reason for
//  each kind of system API the app (DuckDB and its drivers included) calls.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("The privacy manifest")
struct PrivacyManifestTests {
    @Test("no tracking, nothing collected, a reason for each API kind the app uses")
    func manifest() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "no PrivacyInfo.xcprivacy")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        let apis = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = Dictionary(uniqueKeysWithValues: apis.map { ($0["NSPrivacyAccessedAPIType"] as! String, $0["NSPrivacyAccessedAPITypeReasons"] as! [String]) })
        #expect(reasons["NSPrivacyAccessedAPICategoryUserDefaults"] == ["CA92.1"])
        #expect(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"] == ["C617.1", "3B52.1"])
        #expect(reasons["NSPrivacyAccessedAPICategorySystemBootTime"] == ["35F9.1"])
        #expect(reasons["NSPrivacyAccessedAPICategoryDiskSpace"] == ["E174.1"])
    }
}
