#if DEBUG
import os
import SwiftUI

/// Debug-only screen for feasibility spikes. Never compiled into release builds.
/// Spike code here is exploration; production code is rebuilt test-first later.
struct LabView: View {
    @State private var models: [String] = []
    @State private var message = ""

    private let spikes: [(issue: Int, title: String)] = [
        (12, "Model engine: llama.cpp vs MLX"),
        (13, "Constrained structured output"),
        (14, "Offline speech to text"),
        (15, "Document text and tables"),
        (16, "Encryption stack"),
        (17, "Signed, hash-chained evidence")
    ]

    var body: some View {
        List {
            Section("Device") {
                LabeledContent("Free memory for this app", value: freeMemory)
            }
            Section("Models") {
                if models.isEmpty {
                    Text("No models yet. Copy them into the app with Finder, then import.")
                        .foregroundStyle(.secondary)
                }
                ForEach(models, id: \.self) { Text($0).font(.footnote.monospaced()) }
                Button("Import from Finder inbox", action: importModels)
                    .accessibilityHint("Moves model files copied with Finder into the models folder")
                if !message.isEmpty { Text(message).font(.footnote) }
            }
            Section("Spikes") {
                ForEach(spikes, id: \.issue) { spike in
                    LabeledContent("#\(spike.issue)", value: spike.title)
                }
            }
        }
        .navigationTitle("Lab")
        .onAppear(perform: refresh)
    }

    private var freeMemory: String {
        let bytes = Int64(os_proc_available_memory())
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private func refresh() {
        models = (try? ModelStore.live().installedModels()) ?? []
    }

    private func importModels() {
        do {
            let imported = try ModelStore.live().importFromInbox()
            message = imported.isEmpty ? "Nothing to import." : "Imported: \(imported.joined(separator: ", "))"
            refresh()
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}
#endif
