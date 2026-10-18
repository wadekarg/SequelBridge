//
//  HistoryStore.swift
//  SequelBridge
//
//  Persists the statement history the console shows, so it survives a restart.
//  One JSON document per line, append-only; the file is compacted down to the
//  cap when it grows past twice that size, keeping the most recent entries.
//

import Foundation

final class HistoryStore {
    typealias Entry = WorkspaceSession.ConsoleEntry

    private let fileURL: URL
    private let cap: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var appendedSinceCompact = 0

    /// `arguments` picks the support folder (see SupportDirectory) when no `fileURL` is given.
    init(fileURL: URL? = nil, cap: Int = 1000, arguments: [String] = CommandLine.arguments) {
        self.cap = max(1, cap)
        self.fileURL = fileURL ?? SupportDirectory.url(from: arguments).appendingPathComponent("history.jsonl")
    }

    func append(_ entry: Entry) {
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? line.write(to: fileURL, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        }
        appendedSinceCompact += 1
        if appendedSinceCompact >= cap { compact() }
    }

    /// The most recent entries, oldest first, at most `cap` of them.
    func loadRecent() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let entries = text.split(separator: "\n").compactMap { line -> Entry? in
            try? decoder.decode(Entry.self, from: Data(line.utf8))
        }
        return Array(entries.suffix(cap))
    }

    /// Rewrites the file with only the most recent `cap` entries.
    private func compact() {
        appendedSinceCompact = 0
        let keep = loadRecent()
        var data = Data()
        for entry in keep {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
