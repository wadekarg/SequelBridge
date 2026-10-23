//
//  Grants.swift
//  SequelBridge
//
//  What the user let the App Store build reach (the sandbox lets it reach nothing else):
//  folders and files picked in an open panel, kept as security-scoped bookmarks, so a later
//  launch reaches them without asking. ~/.ssh for SSH (its config, keys and known_hosts),
//  the folder holding a SQLite file (SQLite writes its journal beside the file), a key file
//  kept elsewhere. Paths are matched as the file system names them, links resolved, so a
//  symlinked ~/.ssh is its target. A bookmark that no longer leads to its path (the item
//  was moved, renamed or deleted) is forgotten, and the app asks again. Unused in the DMG
//  build.
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
    /// How the user is asked for a path (an open panel there, saying why; `folder` or a
    /// file), returning what they picked. A test answers instead.
    var ask: @MainActor (_ path: String, _ why: String, _ folder: Bool) -> URL? = Grants.panel

    init(defaults: UserDefaults) { self.defaults = defaults }

    private var stored: [String: Data] {
        get { defaults.dictionary(forKey: key) as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// The granted paths, for Settings and the tests.
    var grantedPaths: [String] { stored.keys.sorted() }

    /// `path` as the file system names it: `~` expanded and every symbolic link resolved (a
    /// symlinked ~/.ssh is its target; /var is /private/var), through the longest part of it
    /// that exists, so a path not made yet is named under its real folder. The sandbox lets
    /// this through without a grant. Grants are kept and matched by it: a folder reached
    /// through a link is that folder.
    nonisolated static func canonical(_ path: String) -> String {
        var url = URL(fileURLWithPath: Paths.expandingTilde(path)).standardizedFileURL
        var rest: [String] = []
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        while url.path != "/" {
            if realpath(url.path, &resolved) != nil {
                return rest.reversed().reduce(String(cString: resolved)) { ($0 as NSString).appendingPathComponent($1) }
            }
            rest.append(url.lastPathComponent)
            url.deleteLastPathComponent()
        }
        return "/" + rest.reversed().joined(separator: "/")
    }

    /// Keeps `url`, which the user just picked (an open panel, a file opened with the app).
    func add(_ url: URL) {
        let path = Self.canonical(url.path)
        // Of the item itself, at its real path: a bookmark of a symbolic link can't be made
        // ("Could not open() the item").
        guard let data = try? URL(fileURLWithPath: path).bookmarkData(options: .withSecurityScope,
                                                                      includingResourceValuesForKeys: nil, relativeTo: nil)
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
        let target = Self.canonical(path)
        for (granted, data) in stored where target == granted || target.hasPrefix(granted.hasSuffix("/") ? granted : granted + "/") {
            if let url = open[granted] { return url }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                     bookmarkDataIsStale: &stale),
                  Self.canonical(url.path) == granted, FileManager.default.fileExists(atPath: granted)
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
        guard let url = ask(folder, why, true) else { return nil }
        return accept(url, for: folder)
    }

    func askForFile(_ path: String, why: String) -> URL? {
        guard let url = ask(path, why, false) else { return nil }
        return accept(url, for: path)
    }

    /// The open panel: at `path` (a folder) or beside it (a file), saying why.
    static func panel(_ path: String, _ why: String, _ folder: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.message = why
        panel.prompt = "Allow"
        panel.directoryURL = URL(fileURLWithPath: folder ? path : (path as NSString).deletingLastPathComponent, isDirectory: true)
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - What the App Store build asks for

    /// ~/.ssh itself once a grant reaches it (the grant may be a folder holding it, such as
    /// the home folder), or asked for now. On a Mac where ssh has never run there is no
    /// ~/.ssh to pick, and an open panel can't make one: ssh then keeps the servers it meets
    /// in `own`, a folder of the app's own, and a key file is granted on its own.
    func sshFolder(home: String = Paths.realHome, own: URL = SupportDirectory.url().appendingPathComponent("ssh")) -> URL? {
        let ssh = (home as NSString).appendingPathComponent(".ssh")
        guard FileManager.default.fileExists(atPath: ssh) else {
            try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            return own
        }
        guard covering(ssh) ?? askForFolder(ssh, why: "SSH needs your ~/.ssh folder: its config, keys and known_hosts. "
                                                   + "SequelBridge reads and updates only what ssh does.") != nil
        else { return nil }
        return URL(fileURLWithPath: ssh, isDirectory: true)
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
