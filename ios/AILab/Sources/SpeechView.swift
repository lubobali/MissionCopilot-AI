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
            Section("Record your voice (read the script below)") {
                recordButton(round: "quiet", title: "Record: quiet room")
                recordButton(round: "noisy", title: "Record: noisy (TV or kitchen)")
                Text(model.englishScript).font(.callout)
            }
            Section("Real voice (Documents/voice, English)") {
                Button("6. Run Apple on voice files") { model.runAppleOnVoice() }
                #if canImport(WhisperKit)
                Button("7. Run WhisperKit on voice files") { model.runWhisper(.voice) }
                #endif
            }
            .disabled(model.running || model.isRecording)
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

    /// One recording at a time: while one round records, only its own button (now "Stop") is active.
    private func recordButton(round: String, title: String) -> some View {
        let mine = model.recordingRound == round
        return Button(mine ? "Stop recording" : title) { model.toggleRecording(round: round) }
            .disabled(model.running || (model.isRecording && !mine))
    }
}
