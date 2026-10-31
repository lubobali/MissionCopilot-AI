import SwiftUI

/// Spike #17 screen: sign three items with the chip, then tamper and watch which item breaks.
struct EvidenceView: View {
    @State private var model = EvidenceLabModel()

    var body: some View {
        List {
            Section {
                Text(model.verdict).font(.headline)
            }
            Section("Evidence chain (kandor-roads)") {
                ForEach(model.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Item \(item.id)").font(.body.bold())
                        Text(item.text).font(.footnote)
                    }
                }
            }
            Section("Proofs") {
                Button("1. Sign 3 items with the chip") { model.signThree() }
                Button("2. Tamper: change 1 byte in item 2") { model.tamperItemTwo() }
                Button("3. Cut off the last item") { model.cutLastItem() }
                Button("4. Restore the original") { model.restore() }
                Button("5. Export for the Python check") { model.export() }
            }
            Section("Log") {
                ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
            }
        }
        .navigationTitle("Evidence #17")
    }
}
