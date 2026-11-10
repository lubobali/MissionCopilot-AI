import SwiftUI

/// Opens a mission's report by its id (declared at the stack's root, ContentView).
struct ReportLink: Hashable, Sendable {
    let id: String
}

/// The report page (#161): the aide-memoire written by code from the mission's records, each sentence with
/// numbered proof; the officer removes, adds or edits sentences, then saves a draft.
struct ReportScreen: View {
    let list: MissionListModel
    let id: String
    @State private var model: ReportModel?
    @State private var cannotOpen = false

    var body: some View {
        Group {
            if let model, model.stage == .ready {
                ScrollView { ReportView(model: model) }
            } else if cannotOpen || model?.stage == .cannotOpen {
                Text("The report cannot open. Unlock the app, and make sure the mission's pack is downloaded.")
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                AskOpening(words: "Writing the report from this mission's records…")
            }
        }
        .fieldScreen()
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            guard let store = list.openStore else {
                cannotOpen = true
                return
            }
            let made = ReportModel(mission: id, store: store, send: list.world.sendReport)
            model = made
            await made.load()
        }
    }
}

/// The page without the scrolling, for the screenshot tests too.
struct ReportView: View {
    let model: ReportModel
    @State private var proof: ReportLine?
    @State private var adding: ReportSection?
    @State private var editing: ReportLine?
    @State private var reviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.summary)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(.text))
                Text("Written by code from this mission's records, never by the AI. Tap a number to see the "
                     + "record behind a sentence.")
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryText))
            }
            .accessibilityElement(children: .combine)
            if let words = model.managerWords {  // #193: the manager's decision
                Label(words, systemImage: model.review?.decision == .endorsed ? "checkmark.seal.fill"
                                                                                : "arrow.uturn.backward.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(model.review?.decision == .endorsed ? .success : .warning))
            }
            if !model.walkFinished {
                Label("Finish the site walk to add what you saw.", systemImage: "figure.walk")
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryText))
            }
            ForEach(ReportSection.allCases, id: \.self) { section in sectionView(section) }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(.warning))
            }
            if model.approved == nil {
                Button("Save the draft", systemImage: "square.and.arrow.down", action: model.save)
                    .buttonStyle(.fieldPrimary)
                    .disabled(!model.canSave)
                if let saved = model.saved {
                    Label("Draft saved \(saved.createdAt.formatted(date: .abbreviated, time: .shortened)), "
                          + "\(saved.sentences.count) sentences", systemImage: "checkmark.seal.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color(.success))
                }
                Button("Approve with Face ID", systemImage: "faceid") {
                    Task { await model.approve() }
                }
                .buttonStyle(.fieldPrimary)
                .disabled(!model.canApprove)
                .accessibilityHint("Asks Face ID or your passcode, then signs the report on this iPhone")
                Text(model.approvalHint)
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryText))
            } else {
                Label(model.approvalHint, systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(Color(.success))
                SendSection(model: model) { reviewing = true }
            }
        }
        .padding(16)
        .sheet(item: $proof) { line in ProofSheet(line: line, cards: model.proof(line)) }
        .sheet(isPresented: $reviewing) { SendReview(model: model) { reviewing = false } }
        .sheet(item: $adding) { section in
            SentenceEditor(model: model, section: section, start: nil) { adding = nil }
        }
        .sheet(item: $editing) { line in
            SentenceEditor(model: model, section: line.section, start: line) { editing = nil }
        }
    }

    @ViewBuilder private func sectionView(_ section: ReportSection) -> some View {
        let lines = model.lines.filter { $0.section == section }
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title(model.language))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.secondaryText))
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            ForEach(lines) { line in
                ReportSentence(line: line, number: (model.lines.firstIndex(of: line) ?? 0) + 1,
                               locked: model.approved != nil, onProof: { proof = line }, onEdit: { editing = line },
                               onRemove: { model.remove(line.id) })
            }
            if model.approved == nil {
                Button("Add a sentence", systemImage: "plus") { adding = section }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
        }
    }
}

extension ReportSection: Identifiable {
    var id: String { rawValue }
}
