import SwiftUI

/// Spike #16 screen: the lock label users would see, plus the buttons that prove it on the phone.
struct EncryptionView: View {
    @State private var model = EncryptionLabModel()
    @State private var missionToShred: String?

    var body: some View {
        List {
            Section {
                Label("Encrypted on this iPhone. Only you can open it.", systemImage: "lock.fill")
                    .font(.headline)
            }
            Section("Missions") {
                ForEach(model.missions) { mission in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mission.id).font(.body.bold())
                        Text(mission.text).font(.footnote)
                        Button("Shred mission", role: .destructive) { missionToShred = mission.id }
                            .font(.footnote)
                    }
                }
            }
            Section("Proofs") {
                Button("1. Set up (key, 2 missions, plain twin)") { model.setUp() }
                Button("2. Wrong key is rejected") { model.wrongKey() }
                Button("3. File protection report") { model.protectionReport() }
                Button("4. Lock test (then lock the phone)") { model.lockTest() }
                Button("5. Speed test") { model.speedTest() }
                Button("Reset everything", role: .destructive) { model.resetAll() }
            }
            .disabled(model.running)
            Section("Log") {
                ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
            }
        }
        .navigationTitle("Encryption #16")
        .confirmationDialog("Shred \(missionToShred ?? "")? Its data can never be read again.",
                            isPresented: Binding(get: { missionToShred != nil }, set: { if !$0 { missionToShred = nil } }),
                            titleVisibility: .visible) {
            Button("Shred", role: .destructive) {
                if let missionToShred { model.shred(missionToShred) }
            }
        }
    }
}
