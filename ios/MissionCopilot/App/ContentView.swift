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
                if hub != nil {
                    // Opened by a value, like the mission inside it: SwiftUI shows value pages under pages
                    // opened by a closure, so mixing them hid the workspace under this list (#125).
                    NavigationLink("Missions", value: HomeLink.missions)
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
            // Every page opened by a value is declared here, at the stack's root (scripts/test_navigation.py).
            .navigationDestination(for: HomeLink.self) { _ in
                if let hub { MissionListScreen(hub: hub) }
            }
            .navigationDestination(for: MissionLink.self) { link in
                if let model = hub?.model { MissionWorkspaceScreen(model: model, id: link.id) }
            }
            .navigationDestination(for: SiteWalkLink.self) { link in
                if let model = hub?.model { SiteWalkScreen(list: model, id: link.id) }
            }
            .navigationDestination(for: DocumentsLink.self) { link in
                if let model = hub?.model { DocumentsScreen(list: model, id: link.id) }
            }
            .navigationDestination(for: DebriefLink.self) { link in
                DebriefScreen(id: link.id)
            }
            .navigationDestination(for: FactsLink.self) { link in
                if let model = hub?.model { FactReviewScreen(list: model, id: link.id) }
            }
            .navigationDestination(for: RedFlagsLink.self) { link in
                if let model = hub?.model { RedFlagsScreen(list: model, id: link.id, language: link.language) }
            }
        }
    }

    /// The home screen's pages that are opened by a value.
    enum HomeLink: Hashable { case missions }

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
            BrandMedallion()
                .padding(.bottom, 8)
            Text("Mission Copilot")
                .font(.title.bold())
            Text("Offline AI for field missions")
                .foregroundStyle(Color(.secondaryText))
        }
        .multilineTextAlignment(.center)
    }
}
