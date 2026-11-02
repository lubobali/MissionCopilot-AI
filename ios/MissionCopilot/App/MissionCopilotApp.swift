import SwiftUI

@main
struct MissionCopilotApp: App {
    /// Pauses every store before iOS locks its files away, from the first moment the app runs (#69).
    private let suspension = StoreSuspension(observing: .default)

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
