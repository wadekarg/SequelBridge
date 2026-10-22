//
//  HelpLinks.swift
//  SequelBridge
//
//  Where the Help menu and the About window point: the guide on GitHub, the releases,
//  the issue form, the website and the source. Each opens in the browser; the app sends
//  nothing.
//

import Foundation

enum HelpLinks {
    static let github = URL(string: "https://github.com/wadekarg/SequelBridge")!
    /// What each part of the app does (Help → SequelBridge Help).
    static let guide = URL(string: "https://github.com/wadekarg/SequelBridge/blob/main/guide/FEATURES.md")!
    /// Where each statement runs, joins across servers, limits (Help → How Queries Run).
    static let querying = URL(string: "https://github.com/wadekarg/SequelBridge/blob/main/guide/QUERYING.md")!
    static let releaseNotes = URL(string: "https://github.com/wadekarg/SequelBridge/releases")!
    /// GitHub's choice of form: a bug report or a feature request.
    static let reportIssue = URL(string: "https://github.com/wadekarg/SequelBridge/issues/new/choose")!
    static let website = URL(string: "https://sequelbridge.pages.dev")!
}
