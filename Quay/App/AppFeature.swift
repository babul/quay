import ComposableArchitecture

/// Top-level TCA reducer. Owns the `TerminalClient` events subscription and
/// any future cross-feature state (badges, notifications, window restore).
///
/// Tab opening is intentionally handled in `ContentView` (direct call to
/// `TerminalTabManager.openTab(for:)`) because it requires a SwiftData
/// `modelContext` that reducers don't hold.
@Reducer
struct AppFeature {
    struct State: Equatable {}

    enum Action {
        case onAppear
        case terminalEvent(TerminalClient.Event)
    }

    @Dependency(\.terminalClient) var terminalClient

    var body: some ReducerOf<Self> {
        Reduce { _, action in
            switch action {
            case .onAppear:
                return .run { send in
                    for await event in terminalClient.events() {
                        await send(.terminalEvent(event))
                    }
                }
                .cancellable(id: CancelID.eventsSubscription, cancelInFlight: true)

            case .terminalEvent:
                // Placeholder for future cross-feature reactions (badges, etc.)
                return .none
            }
        }
    }

    enum CancelID { case eventsSubscription }
}
