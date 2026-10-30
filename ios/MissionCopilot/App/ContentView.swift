import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "airplane.circle")
                .font(.system(size: 64))
            Text("Mission Copilot")
                .font(.title.bold())
            Text("Offline AI for field missions")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
