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
    let id: String
    @State private var model = DebriefModel()

    var body: some View {
        ScrollView { DebriefView(model: model) }
            .fieldScreen()
            .navigationTitle("Debrief")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { if model.state == .recording { model.cancel() } }  // never record off screen
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
            controls
            status
        }
        .padding(16)
    }

    @ViewBuilder private var controls: some View {
        if model.state == .recording {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Label(model.elapsed, systemImage: "record.circle")
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color(.danger))
                    .onChange(of: context.date) { model.tick() }
                    .accessibilityLabel("Recording, \(model.elapsed)")
            }
            HStack {
                Button("Stop", systemImage: "stop.fill", action: model.stop)
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
            Label("Recorded \(DebriefModel.clock(seconds))", systemImage: "checkmark.circle.fill")
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
