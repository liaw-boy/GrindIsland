import Foundation
import Sparkle

/// In-app updates through Sparkle: checks the appcast on GitHub Releases (Info.plist `SUFeedURL`) once a day,
/// and every download must carry an EdDSA signature matching `SUPublicEDKey` before it is installed.
final class Updater {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    /// Only the bundled app has a feed; the bare executable (swift run, tests) skips updates.
    var available: Bool { controller != nil }

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkNow() { controller?.checkForUpdates(nil) }

    /// Sparkle's own daily check (stored by Sparkle in the app's preferences).
    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}
