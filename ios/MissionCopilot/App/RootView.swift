import SwiftUI

/// The lock screen or the app, and the privacy cover on top whenever the app is not in front (#73).
/// The mission list lives here, above the lock, so its downloads outlive a lock (#92).
struct RootView: View {
    let session: AppSession
    @State private var hub: MissionsHub

    init(session: AppSession) {
        self.session = session
        _hub = State(initialValue: Connection.missionsHub(user: AppSession.localProfile) { [session] in
            session.opened?.missions
        })
    }

    var body: some View {
        ZStack {
            if session.state.isLocked {
                LockScreen(session: session)
            } else {
                ContentView(notice: ShreddedNotice.text(for: session.opened?.shredded ?? []),
                            onLock: session.lock, missions: { session.opened?.missions }, hub: hub)
            }
            if session.state.coversContent, !session.state.isLocked {
                PrivacyCover()
            }
        }
        .tint(Color(.accent))  // toolbars and alerts too, not only screen content
        .onChange(of: session.state.isLocked) { _, locked in
            if !locked { Task { await hub.unlocked() } }
        }
    }
}

extension AppLockState.Phase {
    init(_ phase: ScenePhase) {
        self = switch phase {
        case .active: .active
        case .inactive: .inactive
        default: .background
        }
    }
}
