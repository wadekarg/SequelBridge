//
//  Distribution.swift
//  SequelBridge
//
//  Which build this is. The DMG/Homebrew build (SequelBridge target) runs as any Mac app;
//  the App Store build (SequelBridgeAppStore target, compiled with APP_STORE) runs in the
//  App Sandbox, which refuses Unix sockets, even in a folder the user granted, and
//  ssh-agent's socket, and lets the app reach only what the user grants (Grants).
//

import Foundation

nonisolated enum Distribution: Equatable {
    case direct, appStore

    static let current: Distribution = {
        #if APP_STORE
        return .appStore
        #else
        return .direct
        #endif
    }()

    /// Connections by Unix socket (MySQL's /tmp/mysql.sock, PostgreSQL's socket folder).
    var offersSockets: Bool { self == .direct }
    /// Logins with keys held by ssh-agent.
    var offersSSHAgent: Bool { self == .direct }
    /// The user grants ~/.ssh, a SQLite file's folder, a key file once (an open panel).
    var needsGrants: Bool { self == .appStore }
}
