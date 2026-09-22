import Combine
import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController {
    private let controller: SPUStandardUpdaterController
    private var observation: AnyCancellable?
    private(set) var canCheckForUpdates = false

    init(
        feedURL: String? = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
        start: (() -> Void)? = nil
    ) {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
        if feedURL != nil {
            if let start {
                start()
            } else {
                controller.startUpdater()
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
