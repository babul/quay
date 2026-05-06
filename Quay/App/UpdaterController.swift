import Combine
import Sparkle
import SwiftUI

@Observable @MainActor
final class UpdaterViewModel {
    var canCheckForUpdates = false
    let controller: SPUStandardUpdaterController
    @ObservationIgnored private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        bindCanCheckForUpdates()
    }

    private func bindCanCheckForUpdates() {
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
    }
}

struct CheckForUpdatesMenuItem: View {
    var model: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…") { model.controller.checkForUpdates(nil) }
            .disabled(!model.canCheckForUpdates)
    }
}
