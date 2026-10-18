//
//  ConnectionStore.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import Foundation

/// The saved connection list on disk. A *fixture* store (`fixture: true`, chosen
/// with the launch argument `-SBConnectionsFile <path>`) is read-only and may carry
/// a `password` per connection — for demo and screenshot instances that can't use
/// the owner's Keychain; those passwords live in memory only and the file is never
/// written, so the fixture keeps them.
final class ConnectionStore {
    private let fileURL: URL
    private let fixture: Bool
    /// Inline passwords of a fixture file, keyed by connection id. Empty otherwise.
    private(set) var inlinePasswords: [UUID: String] = [:]

    /// `arguments` picks the support folder (see SupportDirectory) when no `fileURL` is given.
    init(fileURL: URL? = nil, fixture: Bool = false, arguments: [String] = CommandLine.arguments) {
        self.fixture = fixture
        self.fileURL = fileURL ?? SupportDirectory.url(from: arguments).appendingPathComponent("connections.json")
    }

    /// The path given after `-SBConnectionsFile` in the launch arguments, if any.
    static func fixtureURL(from arguments: [String]) -> URL? {
        guard let i = arguments.firstIndex(of: "-SBConnectionsFile"), i + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[i + 1])
    }

    func load() throws -> [Connection] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        // Decode element-by-element so one corrupt/incompatible entry can't discard
        // every saved connection. Enum fields already fall back to safe defaults
        // (see DatabaseEngine/ConnectionType); this guards structural corruption too.
        let entries = try JSONDecoder().decode([FailableConnection].self, from: data)
        if fixture {
            let secrets = try JSONDecoder().decode([InlineSecret].self, from: data)
            inlinePasswords = Dictionary(uniqueKeysWithValues: secrets.compactMap { s in
                s.password.map { (s.id, $0) }
            })
        }
        return entries.compactMap(\.value)
    }

    /// Decodes a Connection but degrades a decode failure to nil instead of
    /// aborting the surrounding array decode.
    private struct FailableConnection: Decodable {
        let value: Connection?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Connection.self)
        }
    }

    /// The `password` a fixture entry may carry beside its `id`.
    private struct InlineSecret: Decodable {
        let id: UUID
        let password: String?
    }

    func save(_ connections: [Connection]) throws {
        guard !fixture else { return }   // a fixture is read-only: it keeps its passwords
        let data = try JSONEncoder().encode(connections)
        try data.write(to: fileURL, options: .atomic)
    }
}
