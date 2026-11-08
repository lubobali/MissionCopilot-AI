import SwiftUI

/// Opens the notes review of one debrief (declared at the stack's root, ContentView).
struct DebriefNotesLink: Hashable, Sendable {
    let id: String
    let seq: Int
}

/// The notes review (#142): the assistant's notes with the words they came from, and every heard number with
/// the words around it; the officer decides each one, then saves.
struct DebriefNotesScreen: View {
    let list: MissionListModel
    let link: DebriefNotesLink
    @State private var review: DebriefReviewModel?
    @State private var cannotOpen = false

    var body: some View {
        Group {
            if let review {
                ScrollView { DebriefNotesView(model: review) }
            } else if cannotOpen {
                Text("The notes cannot open. Unlock the app and try again.")
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                Loading(text: "Opening the debrief")
            }
        }
        .fieldScreen()
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard review == nil else { return }
            guard let store = list.openStore,
                  let debrief = (try? store.debriefs(in: link.id))?.first(where: { $0.seq == link.seq }) else {
                cannotOpen = true
                return
            }
            let model = DebriefReviewModel.load(mission: link.id, debrief: debrief, store: store)
            review = model
            await model.draft()
        }
    }
}

/// The page without the scrolling, for the screenshot tests too.
struct DebriefNotesView: View {
    let model: DebriefReviewModel
    @State private var newNote = ""
    @State private var newKind = DebriefNote.Kind.action

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.stage {
            case .drafting:
                Loading(text: "The assistant is drafting the notes")
            case .noTranscript:
                note("This debrief has no text yet. Open the Debrief page to turn it into text.", icon: "text.bubble")
            case .alreadySaved:
                note("The notes of this debrief are saved.", icon: "checkmark.seal.fill", role: .success)
            case .toOfficer(let why):
                note(why.words, icon: "person.fill.questionmark")
                Button("Write the notes yourself", systemImage: "square.and.pencil", action: model.writeYourself)
                    .buttonStyle(.fieldPrimary)
            case .review:
                review
            case .saved(let count):
                note("\(count) notes and numbers saved, each linked to the recording.", icon: "checkmark.seal.fill",
                     role: .success)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var review: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.summary)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(.text))
            Text("Check each note against what was said, and each number against what you meant. Speech can "
                 + "mishear numbers. Nothing is saved until all are decided.")
                .font(.footnote)
                .foregroundStyle(Color(.secondaryText))
        }
        .accessibilityElement(children: .combine)
        ForEach(model.notes) { line in
            NoteCard(line: line, onDecide: { model.decide(note: line.id, $0) }, onUndo: { model.undo(note: line.id) })
        }
        HStack {
            Picker("Kind", selection: $newKind) {
                ForEach(DebriefNote.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            TextField("Add a note", text: $newNote)
                .textFieldStyle(.roundedBorder)
            Button("Add") {
                model.addNote(newKind, newNote)
                newNote = ""
            }
            .disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if !model.numbers.isEmpty {
            Text("Numbers heard")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.secondaryText))
                .textCase(.uppercase)
        }
        ForEach(model.numbers) { line in
            NumberCard(line: line, onConfirm: { model.decide(number: line.id, .confirm) },
                       onCorrect: { model.correct(number: line.id, to: $0) }, onUndo: { model.undo(number: line.id) })
        }
        if let problem = model.problem { note(problem, icon: "exclamationmark.triangle.fill", role: .warning) }
        Button("Save the notes", systemImage: "checkmark.seal", action: model.save)
            .buttonStyle(.fieldPrimary)
            .disabled(!model.canSave)
    }

    private func note(_ text: String, icon: String, role: ColorRole = .secondaryText) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(Color(role))
    }
}
