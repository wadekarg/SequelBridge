//
//  SupportDirectory.swift
//  SequelBridge
//
//  Where the app keeps its files: Application Support/SequelBridge, or the folder
//  named by the launch argument `-SBSupportDir <path>`. Demo and screenshot
//  instances pass the argument so their statement history, saved queries and
//  connection list stay apart from the owner's.
//

import Foundation

enum SupportDirectory {
    /// The folder, created on demand. A dangling or empty `-SBSupportDir` is ignored.
    static func url(from arguments: [String] = CommandLine.arguments) -> URL {
        let dir: URL
        if let i = arguments.firstIndex(of: "-SBSupportDir"), i + 1 < arguments.count, !arguments[i + 1].isEmpty {
            dir = URL(fileURLWithPath: arguments[i + 1])
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            dir = base.appendingPathComponent("SequelBridge")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
