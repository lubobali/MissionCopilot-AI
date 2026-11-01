import SwiftUI

/// Spike #14 screen: transcribe the two debrief recordings offline with each engine; code scores them.
struct SpeechView: View {
    @State private var model = SpeechLabModel()

    var body: some View {
        List {
            Section("Apple SpeechTranscriber") {
                Button("1. Apple status (available, languages)") { model.appleStatus() }
                Button("2. Install English + French (online, once)") { model.appleInstall() }
                Button("3. Run Apple on both debriefs") { model.runApple() }
            }
            .disabled(model.running)
            Section("Real voice (Documents/voice, English)") {
                Button("6. Run Apple on voice files") { model.runAppleOnVoice() }
                #if canImport(WhisperKit)
                Button("7. Run WhisperKit on voice files") { model.runWhisper(.voice) }
                #endif
            }
            .disabled(model.running)
            #if canImport(WhisperKit)
            Section("WhisperKit large-v3 (626 MB, from Documents/whisperkit)") {
                Button("4. Run WhisperKit on both debriefs") { model.runWhisper() }
                Button("5. WhisperKit French again: VAD, then no chunking") { model.runWhisper(.frenchRepeat) }
            }
            .disabled(model.running)
            #endif
            Section("Log") {
                ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
            }
        }
        .navigationTitle("Speech #14")
    }
}
