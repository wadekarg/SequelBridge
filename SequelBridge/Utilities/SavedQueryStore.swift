//
//  SavedQueryStore.swift
//  SequelBridge
//
//  Named, reusable SQL snippets that persist across launches — the "saved
//  queries" / "favorites" feature Sequel Ace and MySQL Workbench both have.
//  Stored as a single JSON array in Application Support; the list is small, so
//  it's rewritten whole rather than append-only like the statement history.
//

import Foundation

struct SavedQuery: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var sql: String
    var createdAt: Date = Date()
}

final class SavedQueryStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// `arguments` picks the support folder (see SupportDirectory) when no `fileURL` is given.
    init(fileURL: URL? = nil, arguments: [String] = CommandLine.arguments) {
        self.fileURL = fileURL ?? SupportDirectory.url(from: arguments).appendingPathComponent("saved_queries.json")
        encoder.outputFormatting = [.prettyPrinted]
    }

    /// Tolerant load: a corrupt file yields an empty list rather than throwing,
    /// matching how connections load (one bad file must not break the app).
    func load() -> [SavedQuery] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([SavedQuery].self, from: data)) ?? []
    }

    func save(_ queries: [SavedQuery]) {
        guard let data = try? encoder.encode(queries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Adds a query, replacing any existing one with the same (case-insensitive)
    /// name so re-saving under a known name updates it instead of duplicating.
    /// Returns the updated list.
    func upsert(_ query: SavedQuery, into list: [SavedQuery]) -> [SavedQuery] {
        var out = list.filter { $0.name.caseInsensitiveCompare(query.name) != .orderedSame }
        out.append(query)
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save(out)
        return out
    }

    func remove(id: UUID, from list: [SavedQuery]) -> [SavedQuery] {
        let out = list.filter { $0.id != id }
        save(out)
        return out
    }
}
