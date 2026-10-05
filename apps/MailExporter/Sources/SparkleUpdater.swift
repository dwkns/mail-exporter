import Combine
import Sparkle
import SwiftUI

enum SparkleConfig {
    static let feedURL = URL(string: "https://github.com/dwkns/mail-exporter/releases/latest/download/appcast.xml")!
}

/// Owns the process-lifetime Sparkle controller. Private EdDSA keys never live here.
@MainActor
final class SparkleController {
    static let shared = SparkleController()

    let controller: SPUStandardUpdaterController

    var updater: SPUUpdater { controller.updater }

    private init() {
        // Sparkle replaces the whole app. Only turn that on when this copy is
        // already the public stamp. The personal app stays on the safe checker,
        // which refuses a download that would make macOS ask for disk access again.
        let sparkleMayReplace = AppStamp.isDeveloperIDApplication()
        controller = SPUStandardUpdaterController(
            startingUpdater: sparkleMayReplace,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates =
            sparkleMayReplace && AppPreferences.shared.autoCheckUpdates
    }

    func applyAutomaticChecks(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdatesUI() {
        controller.checkForUpdates(nil)
    }

    func checkForUpdatesInBackground() {
        guard updater.automaticallyChecksForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var model: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        model = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            AppUpdater.shared.showUpdateWindow()
        }
        .disabled(!model.canCheckForUpdates)
    }
}
