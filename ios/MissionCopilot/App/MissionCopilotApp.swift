import SwiftUI

@main
struct MissionCopilotApp: App {
    /// Pauses every store before iOS locks its files away, from the first moment the app runs (#69).
    private let suspension = StoreSuspension(observing: .default)
    /// The app lock (#73): Face ID or the passcode, then the user's missions open with that same proof.
    @State private var session = AppSession(authenticator: LocalAuthenticator(), policy: AppLockPolicy()) { proof in
        try UserStore.openMissions(user: AppSession.localProfile, in: UserStore.live.base,
                                   keys: UserStore.live.keys, vault: UserStore.live.vault, context: proof)
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .onChange(of: scenePhase) { _, phase in
                    session.sceneChanged(to: AppLockState.Phase(phase), at: Date())
                }
        }
    }
}
