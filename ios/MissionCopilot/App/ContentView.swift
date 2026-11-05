import SwiftUI

struct ContentView: View {
    /// Missions the lease check just destroyed, in plain words (nil when none).
    var notice: String?
    var onLock: () -> Void = {}
    /// The open store's missions, for a shred order (nil while locked).
    var missions: @MainActor () -> MissionStore? = { nil }
    /// The mission list (nil in previews and tests that draw only this screen).
    var hub: MissionsHub?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HomeTitle()
                if let notice = Self.notice(lease: notice, shred: hub?.shredNotice) {
                    Text(notice)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                if let hub {
                    NavigationLink("Missions") { MissionListScreen(hub: hub) }
                        .buttonStyle(.fieldPrimary)
                        .padding(.top, 24)
                }
                NavigationLink("Connect this iPhone") {
                    ConnectionScreen(user: AppSession.localProfile, missions: missions)
                }
                    .buttonStyle(.fieldSecondary)
                    .padding(.top, hub == nil ? 24 : 0)
                NavigationLink("Licenses") { AcknowledgementsView() }
                    .buttonStyle(.fieldSecondary)
                #if DEBUG
                NavigationLink("Lab (debug only)") { LabView() }
                    .buttonStyle(.fieldSecondary)
                #endif
            }
            .padding(24)
            .fieldScreen()
            .toolbar {
                Button("Lock", systemImage: "lock", action: onLock)
            }
        }
    }

    /// The home screen's notice: what the lease check destroyed, then what a shred order destroyed (#94).
    static func notice(lease: String?, shred: String?) -> String? {
        let parts = [lease, shred].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The top of the home screen: the developer's logo joined to our airplane (#123), then the app's name.
struct HomeTitle: View {
    var body: some View {
        VStack(spacing: 12) {
            BrandLockup()
                .padding(.bottom, 4)
            Text("Mission Copilot")
                .font(.title.bold())
            Text("Offline AI for field missions")
                .foregroundStyle(Color(.secondaryText))
        }
        .multilineTextAlignment(.center)
    }
}
