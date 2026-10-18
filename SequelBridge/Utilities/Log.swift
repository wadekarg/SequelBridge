//
//  Log.swift
//  SequelBridge
//
//  Diagnostic logging through the unified logging system (visible in Console.app
//  under the app's bundle identifier), one category per subsystem of the app.
//  Values that identify a user's servers are left at the default (private)
//  visibility; names of extensions, aliases and error text are public so a log a
//  user sends along with a bug report is readable.
//

import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "SequelBridge"
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let connections = Logger(subsystem: subsystem, category: "connections")
}
