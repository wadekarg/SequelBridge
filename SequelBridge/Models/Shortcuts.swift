//
//  Shortcuts.swift
//  SequelBridge
//
//  The keys Settings lists, and guide/FEATURES.md with it. ShortcutListTests checks every
//  key a button binds is here; the editor's own keys (SQLTextView) and ⌘1–⌘9 are added
//  by hand.
//

import Foundation

nonisolated enum Shortcuts {
    struct Entry { let keys: String; let action: String }

    static let all: [Entry] = [
        .init(keys: "⌘↵", action: "Run every statement, or the selected text"),
        .init(keys: "⌘R", action: "Run the statement under the cursor; in Content and Structure, refresh"),
        .init(keys: "⌥⌘R", action: "Run every statement"),
        .init(keys: "Esc", action: "Cancel the running query"),
        .init(keys: "⌃⌥F", action: "Format the statement"),
        .init(keys: "⌘T", action: "New query tab"),
        .init(keys: "⌘W", action: "Close the query tab you're on"),
        .init(keys: "⌘O", action: "Open a .sql file"),
        .init(keys: "⌘S", action: "Save the query tab's .sql file"),
        .init(keys: "⇧⌘S", action: "Save it under another name"),
        .init(keys: "⌘/", action: "Comment or uncomment the lines"),
        .init(keys: "⌘]", action: "Indent the lines"),
        .init(keys: "⌘[", action: "Outdent the lines"),
        .init(keys: "⌘F", action: "Find in the editor"),
        .init(keys: "⌘G", action: "Find the next match"),
        .init(keys: "⌘1–⌘9", action: "Structure, Content, Relations, Triggers, Table Info, Query, Routines, Server, Console"),
        .init(keys: "⇧⌘R", action: "Refresh the databases and tables"),
        .init(keys: "⌃⌘R", action: "Refresh the tables"),
        .init(keys: "⌘J", action: "Jump to a page, or set the rows a page shows (Content)"),
        .init(keys: "⌘D", action: "Duplicate the selected row (Content)"),
        .init(keys: "⌘,", action: "Settings"),
        .init(keys: "Click a table", action: "Insert its name at the cursor"),
        .init(keys: "Double-click a table", action: "SELECT * … LIMIT 200 in a new query tab"),
    ]
}
