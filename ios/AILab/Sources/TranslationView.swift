import SwiftUI
import Translation

/// Spike #18 screen: Apple translation offline, French debrief to English, facts scored by code.
struct TranslationView: View {
    @State private var model = TranslationLabModel()

    var body: some View {
        List {
            Section("Apple Translation") {
                Button("1. Translation status (languages)") { model.status() }
                Button("2. Install French -> English (online, once)") { model.requestInstall() }
                Button("3. Translate the French debrief (offline)") { model.run() }
            }
            .disabled(model.running)
            Section("Log") {
                ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
            }
        }
        .navigationTitle("Translation #18")
        .translationTask(model.installConfiguration) { session in await model.install(with: session) }
    }
}
