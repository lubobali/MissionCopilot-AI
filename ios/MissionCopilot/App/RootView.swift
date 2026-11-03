import SwiftUI

/// The lock screen or the app, and the privacy cover on top whenever the app is not in front (#73).
struct RootView: View {
    let session: AppSession

    var body: some View {
        ZStack {
            if session.state.isLocked {
                LockScreen(session: session)
            } else {
                ContentView(notice: ShreddedNotice.text(for: session.opened?.shredded ?? []),
                            onLock: session.lock)
            }
            if session.state.coversContent, !session.state.isLocked {
                PrivacyCover()
            }
        }
        .tint(Color(.accent))  // toolbars and alerts too, not only screen content
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
