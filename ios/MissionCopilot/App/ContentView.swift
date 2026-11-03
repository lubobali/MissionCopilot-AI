import SwiftUI

struct ContentView: View {
    /// Missions the lease check just destroyed, in plain words (nil when none).
    var notice: String?
    var onLock: () -> Void = {}

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "airplane.circle")
                    .font(.system(size: 64))
                    .accessibilityHidden(true)
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
                NavigationLink("Licenses") { AcknowledgementsView() }
                    .padding(.top, 24)
                #if DEBUG
                NavigationLink("Lab (debug only)") { LabView() }
                    .padding(.top, 24)
                #endif
            }
            .padding()
            .toolbar {
                Button("Lock", systemImage: "lock", action: onLock)
            }
        }
    }
}
