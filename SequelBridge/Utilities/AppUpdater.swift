//
//  AppUpdater.swift
//  SequelBridge
//
//  New versions, checked for and installed by Sparkle (https://sparkle-project.org), in the
//  DMG/Homebrew build: nothing else would tell its users there is one. The feed is
//  appcast.xml on the latest GitHub release (Info.plist's SUFeedURL), and an update whose
//  signature doesn't match the project's key (SUPublicEDKey) is refused. Sparkle asks once,
//  at the second launch, whether to check automatically. The App Store build has no updater
//  and no Sparkle: the App Store updates it.
//

#if !APP_STORE
import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// Whether Check for Updates… can run now (not while a check is going).
    @Published private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?
    nonisolated let feedOverride: String?

    init(arguments: [String] = CommandLine.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        feedOverride = Self.feedOverride(arguments)
        super.init()
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        guard Self.startsUpdater(arguments: arguments, environment: environment, debugBuild: debugBuild) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// Whether this copy runs the updater at all (see startsUpdater).
    var isRunning: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// Sparkle's own setting, kept in the app's defaults.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Whether a copy runs the updater: not a test run, a copy launched with files of its
    /// own (the UI tests, the screenshots) or a Debug build, each of which would ask
    /// whether to check automatically and fetch the feed. -SBUpdateFeed, the updater's own
    /// check, starts it anyway.
    nonisolated static func startsUpdater(arguments: [String], environment: [String: String], debugBuild: Bool) -> Bool {
        if feedOverride(arguments) != nil { return true }
        if debugBuild || environment["XCTestConfigurationFilePath"] != nil { return false }
        return !arguments.contains("-SBSupportDir") && !arguments.contains("-SBConnectionsFile")
    }

    /// The feed named after -SBUpdateFeed, if any.
    nonisolated static func feedOverride(_ arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "-SBUpdateFeed"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { feedOverride }

    /// The question whether to check automatically: not for a copy checking a feed of a
    /// test's own.
    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { feedOverride == nil }
}
#endif

#if APP_STORE
import Combine
import Foundation

/// The App Store build: the App Store updates the app, so it has no updater of its own and
/// no Sparkle. The same face as the DMG build's, so the views that use it compile unchanged.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    init(arguments: [String] = CommandLine.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {}
    var isRunning: Bool { false }
    func checkForUpdates() {}
    var automaticallyChecksForUpdates: Bool {
        get { false }
        set {}
    }
}
#endif
