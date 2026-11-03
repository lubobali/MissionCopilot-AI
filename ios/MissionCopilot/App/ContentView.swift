import SwiftUI

struct ContentView: View {
    /// Missions the lease check just destroyed, in plain words (nil when none).
    var notice: String?
    var onLock: () -> Void = {}

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HeroIcon(systemName: "airplane.circle")
                Text("Mission Copilot")
                    .font(.title.bold())
                Text("Offline AI for field missions")
                    .foregroundStyle(Color(.secondaryText))
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                NavigationLink("Connect this iPhone") { ConnectionScreen(user: AppSession.localProfile) }
                    .buttonStyle(.fieldSecondary)
                    .padding(.top, 24)
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
}
