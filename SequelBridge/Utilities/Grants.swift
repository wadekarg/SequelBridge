//
//  Grants.swift
//  SequelBridge
//
//  What the user let the App Store build reach (the sandbox lets it reach nothing else):
//  folders and files picked in an open panel, kept as security-scoped bookmarks, so a later
//  launch reaches them without asking. ~/.ssh for SSH (its config, keys and known_hosts),
//  the folder holding a SQLite file (SQLite writes its journal beside the file), a key file
//  kept elsewhere. A bookmark that no longer leads to its path (the item was moved,
//  renamed or deleted) is forgotten, and the app asks again. Unused in the DMG build.
//

import AppKit
import Foundation

@MainActor
final class Grants {
    static let shared = Grants(defaults: .standard)

    private let defaults: UserDefaults
    private let key = "SBGrants"
    /// Granted paths whose access is started, for the app's lifetime.
    private var open: [String: URL] = [:]

    init(defaults: UserDefaults) { self.defaults = defaults }

    private var stored: [String: Data] {
        get { defaults.dictionary(forKey: key) as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// The granted paths, for Settings and the tests.
    var grantedPaths: [String] { stored.keys.sorted() }

    /// Keeps `url`, which the user just picked (an open panel, a file opened with the app).
    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        stored[path] = data
        open[path] = nil
    }

    func forget(_ path: String) {
        stored[path] = nil
        open[path]?.stopAccessingSecurityScopedResource()
        open[path] = nil
    }

    /// The grant that is `path` or holds it, its access started; nil when there is none or
    /// when its bookmark no longer leads to the path it was given for.
    func covering(_ path: String) -> URL? {
        let target = URL(fileURLWithPath: Paths.expandingTilde(path)).standardizedFileURL.path
        for (granted, data) in stored where target == granted || target.hasPrefix(granted.hasSuffix("/") ? granted : granted + "/") {
            if let url = open[granted] { return url }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                     bookmarkDataIsStale: &stale),
                  url.standardizedFileURL.path == granted, FileManager.default.fileExists(atPath: granted)
            else { forget(granted); continue }
            _ = url.startAccessingSecurityScopedResource()
            if stale { add(url) }
            open[granted] = url
            return url
        }
        return nil
    }

    /// Keeps what the user picked when asked for `needed`, and says whether it reaches it.
    func accept(_ picked: URL, for needed: String) -> URL? {
        add(picked)
        return covering(needed)
    }

    // MARK: - Asking (an open panel, there, saying why)

    func askForFolder(_ folder: String, why: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = why
        panel.prompt = "Allow"
        panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return accept(url, for: folder)
    }

    func askForFile(_ path: String, why: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = why
        panel.prompt = "Allow"
        panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return accept(url, for: path)
    }

    // MARK: - What the App Store build asks for

    /// ~/.ssh, granted or asked for now.
    func sshFolder() -> URL? {
        let ssh = Paths.realHome + "/.ssh"
        return covering(ssh) ?? askForFolder(ssh, why: "SSH needs your ~/.ssh folder: its config, keys and known_hosts. "
                                                   + "SequelBridge reads and updates only what ssh does.")
    }

    /// A key file, granted (or in a granted folder) or asked for now.
    func file(_ path: String) -> URL? {
        let full = Paths.expandingTilde(path)
        return covering(full) ?? askForFile(full, why: "Choose the SSH key \((full as NSString).lastPathComponent) so ssh can read it.")
    }

    /// The folder holding a SQLite file, granted or asked for now.
    func folder(holding path: String) -> URL? {
        let full = Paths.expandingTilde(path)
        let folder = (full as NSString).deletingLastPathComponent
        return covering(full) ?? askForFolder(folder, why: "SQLite writes beside \((full as NSString).lastPathComponent): "
                                                        + "allow its folder so SequelBridge can open and change it.")
    }
}
