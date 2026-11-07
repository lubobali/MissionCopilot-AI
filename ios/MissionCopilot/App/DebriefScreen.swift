import SwiftUI

/// Opens a mission's debriefs by its id (declared at the stack's root, ContentView).
struct DebriefLink: Hashable, Sendable {
    let id: String
}

/// Debriefs on the workspace (#142): opens the Debrief page.
struct DebriefCard: View {
    static let start = "Record a voice debrief after a meeting"
    let summary: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(Color(.accent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Debrief")
                    .font(.headline)
                    .foregroundStyle(Color(.text))
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryText))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(Color(.secondaryText))
                .accessibilityHidden(true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

/// The Debrief page: the consent line, then record with a timer, stop, or cancel.
struct DebriefScreen: View {
    let list: MissionListModel
    let id: String
    @State private var model: DebriefModel?
    @State private var cannotOpen = false

    var body: some View {
        Group {
            if let model {
                ScrollView { DebriefView(model: model) }
                    .onDisappear { if model.state == .recording { model.cancel() } }  // never record off screen
            } else if cannotOpen {
                Text("The debriefs cannot open. Unlock the app and try again.")
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                Loading(text: "Opening the debriefs")
            }
        }
        .fieldScreen()
        .navigationTitle("Debrief")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            guard let store = list.openStore else {
                cannotOpen = true
                return
            }
            let made = DebriefModel(mission: id, store: store)
            model = made
            await made.loadAndRead()
        }
    }
}

/// The page without the scrolling, for the screenshot tests too.
struct DebriefView: View {
    @Bindable var model: DebriefModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speak what was decided, who will do what and by when, and the risks you saw.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(.text))
                Text("Recorded and kept on this iPhone only, sealed with the mission key, offline. Up to 5 minutes.")
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryText))
            }
            .accessibilityElement(children: .combine)
            Toggle("I am recording only myself, or people who agreed to be recorded.", isOn: $model.consent)
                .font(.subheadline)
                .disabled(model.state == .recording)
            Picker("Language", selection: $model.language) {
                ForEach(SpeechLanguage.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.state == .recording)
            controls
            status
            ForEach(model.debriefs.reversed()) { debrief in
                DebriefRow(debrief: debrief, transcript: model.transcripts[debrief.seq] ?? .reading,
                           notesSaved: model.confirmed.contains(debrief.seq), mission: model.mission) {
                    Task { await model.retry(debrief.seq) }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder private var controls: some View {
        if model.state == .recording {
            TimelineView(.periodic(from: .now, by: 0.08)) { context in
                VStack(alignment: .leading, spacing: 14) {
                    Label(model.elapsed, systemImage: "record.circle")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color(.danger))
                        .accessibilityLabel("Recording, \(model.elapsed)")
                    VoiceBars(levels: model.levels)
                }
                .onChange(of: context.date) { model.tick() }
            }
            HStack {
                Button("Stop", systemImage: "stop.fill") {
                    model.stop()
                    Task { await model.readWaiting() }
                }
                    .buttonStyle(.fieldPrimary)
                Button("Cancel", action: model.cancel)
                    .buttonStyle(.fieldSecondary)
            }
        } else {
            Button("Record a debrief", systemImage: "mic.fill") { Task { await model.record() } }
                .buttonStyle(.fieldPrimary)
                .disabled(!model.canRecord)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .recorded(let seconds):
            Label("Recorded \(DebriefModel.clock(seconds)) and kept as signed evidence",
                  systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Color(.success))
        case .problem(let problem):
            Label(problem.words, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Color(.warning))
        case .idle, .recording:
            EmptyView()
        }
    }
}

/// The voice as moving bars, newest on the right: they rise when the microphone hears speech (found on the
/// iPhone: a timer alone does not show that it hears you).
struct VoiceBars: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color(.accent))
                    .frame(maxWidth: .infinity)
                    .frame(height: 6 + 58 * level)
            }
        }
        .frame(height: 64)
        .animation(.easeOut(duration: 0.08), value: levels)
        .accessibilityHidden(true)  // the timer above says it is recording
    }
}

/// One kept debrief on glass: when, how long, in which language, and what was heard (or why not yet).
struct DebriefRow: View {
    let debrief: Debrief
    var transcript = DebriefModel.TranscriptState.reading
    var notesSaved = false
    var mission = ""
    var onRetry: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .foregroundStyle(Color(.accent))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(debrief.recordedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                        .foregroundStyle(Color(.text))
                    Text("\(DebriefModel.clock(debrief.seconds)) · \(debrief.language.name) · signed evidence")
                        .font(.subheadline)
                        .foregroundStyle(Color(.secondaryText))
                }
                Spacer()
            }
            switch transcript {
            case .reading:
                Label(transcript.words, systemImage: "text.bubble")
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryText))
            case .heard(let text):
                Text(text)
                    .font(.body)
                    .foregroundStyle(Color(.text))
                    .textSelection(.enabled)
                if notesSaved {
                    Label("Notes saved", systemImage: "checkmark.seal.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color(.success))
                } else {
                    NavigationLink(value: DebriefNotesLink(id: mission, seq: debrief.seq)) {
                        Label("Draft the notes", systemImage: "list.bullet.clipboard")
                    }
                    .buttonStyle(.fieldSecondary)
                }
            case .problem:
                Label(transcript.words, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(.warning))
                Button("Try again", systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.fieldSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
    }
}

extension MissionWorkspaceScreen {
    /// The debriefs' summary for their card; nil when the mission has no pack yet or the app is locked.
    static func debriefsSummary(_ row: MissionRow, store: MissionStore?) -> String? {
        guard row.pack != nil, let store, let debriefs = try? store.debriefs(in: row.id) else { return nil }
        return DebriefModel.summary(debriefs)
    }
}
