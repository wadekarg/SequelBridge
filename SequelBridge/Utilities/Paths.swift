//
//  Paths.swift
//  SequelBridge
//
//  "~" in a path the user typed is their home folder. In the App Store build the sandbox
//  gives the app a home of its own (its container), which NSHomeDirectory(), $HOME and
//  NSString's expandingTildeInPath return; the user's is in the user database.
//

import Foundation

nonisolated enum Paths {
    /// The user's home folder, from the user database (getpwuid), whatever the sandbox says.
    static func userHome() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
    }

    static let realHome = userHome()

    /// `path` with a leading "~" or "~/" as the user's home; "~user/…" as NSString expands it
    /// (from the user database too); anything else as typed.
    static func expandingTilde(_ path: String) -> String {
        if path == "~" { return realHome }
        if path.hasPrefix("~/") { return realHome + path.dropFirst() }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        return path
    }
}
