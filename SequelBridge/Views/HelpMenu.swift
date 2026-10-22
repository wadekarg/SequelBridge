//
//  HelpMenu.swift
//  SequelBridge
//
//  The Help menu: the guide, how queries run, keyboard shortcuts, release notes, a way to
//  report an issue, the website and the source (HelpLinks). The links open in the
//  browser; Keyboard Shortcuts opens Settings on its tab.
//

import AppKit
import SwiftUI

struct HelpMenu: View {
    let appSettings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("SequelBridge Help") { open(HelpLinks.guide) }
            .keyboardShortcut("?", modifiers: .command)
        Button("How Queries Run") { open(HelpLinks.querying) }
        Button("Keyboard Shortcuts") {
            appSettings.settingsTab = .shortcuts
            openSettings()
        }
        Divider()
        Button("Release Notes") { open(HelpLinks.releaseNotes) }
        Button("Report an Issue…") { open(HelpLinks.reportIssue) }
        Divider()
        Button("SequelBridge Website") { open(HelpLinks.website) }
        Button("SequelBridge on GitHub") { open(HelpLinks.github) }
    }

    private func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
