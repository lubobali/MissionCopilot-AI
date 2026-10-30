import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "airplane.circle")
                    .font(.system(size: 64))
                    .accessibilityHidden(true)
                Text("Mission Copilot")
                    .font(.title.bold())
                Text("Offline AI for field missions")
                    .foregroundStyle(.secondary)
                #if DEBUG
                NavigationLink("Lab (debug only)") { LabView() }
                    .padding(.top, 24)
                #endif
            }
            .padding()
        }
    }
}
