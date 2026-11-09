import SwiftUI

/// Opens the review of a mission's scanned facts by its id (declared at the stack's root, ContentView).
struct FactsLink: Hashable, Sendable {
    let id: String
}

/// The review page (#138): the assistant's 8 facts from the scanned pages, each with where it was printed
/// and its checks; the officer confirms or corrects each one, then saves them.
struct FactReviewScreen: View {
    let list: MissionListModel
    let id: String
    @State private var review: FactReviewModel?
    @State private var cannotOpen = false

    var body: some View {
        Group {
            if let review {
                ScrollView { FactReviewView(model: review) }
            } else if cannotOpen {
                Text("The facts cannot open. Unlock the app and try again.")
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                Loading(text: "Opening the facts")
            }
        }
        .fieldScreen()
        .navigationTitle("Facts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard review == nil else { return }
            guard let store = list.openStore else {
                cannotOpen = true
                return
            }
            let model = FactReviewModel.load(mission: id, store: store)
            review = model
            await model.read()
        }
    }
}

/// The page without the scrolling, for the screenshot tests too.
struct FactReviewView: View {
    let model: FactReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.stage {
            case .reading:
                Loading(text: "The assistant is reading the pages")
            case .noPages:
                note("No new pages to read. Scan the invoice and the progress report first.", icon: "doc.viewfinder")
            case .toOfficer(let why):
                note(why.words, icon: "person.fill.questionmark")
                Button("Enter the facts yourself", systemImage: "square.and.pencil", action: model.enterYourself)
                    .buttonStyle(.fieldPrimary)
            case .review:
                header
                ForEach(model.lines) { line in
                    FactCard(line: line, onConfirm: { model.confirm(line.field) },
                             onCorrect: { model.correct(line.field, to: $0, anyway: $1) },
                             onUndo: { model.undo(line.field) })
                }
                if let problem = model.problem, model.problemField == nil {
                    note(problem, icon: "exclamationmark.triangle.fill", role: .warning)
                }
                Button("Save the 8 facts", systemImage: "checkmark.seal", action: model.save)
                    .buttonStyle(.fieldPrimary)
                    .disabled(!model.canSave)
            case .saved(let count):
                note("\(count) facts saved, each with its page. The red flags use them now.",
                     icon: "checkmark.seal.fill", role: .success)
            }
        }
        .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.summary)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(.text))
            Text("Check each fact against the page: confirm it, or correct it. Nothing is saved until all 8 "
                 + "are decided. Read by the assistant on this iPhone; the checks are done by code.")
                .font(.footnote)
                .foregroundStyle(Color(.secondaryText))
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String, icon: String, role: ColorRole = .secondaryText) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(Color(role))
    }
}

/// One fact on glass: its name and value, where it was printed, its problems, and Confirm or Correct.
struct FactCard: View {
    let line: FactReviewModel.Line
    var onConfirm: () -> Void = {}
    /// The typed value, and whether the officer keeps it although it is not on the pages (#151).
    var onCorrect: (String, Bool) -> Bool = { _, _ in false }
    var onUndo: () -> Void = {}
    @State private var typed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(line.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.secondaryText))
                    .textCase(.uppercase)
                Text(line.value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(.text))
                Label(line.found, systemImage: line.canConfirm ? "text.magnifyingglass" : "questionmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryText))
                ForEach(line.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color(.warning))
                }
                if let decision = line.decision {
                    Label(decision, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.success))
                }
            }
            .accessibilityElement(children: .combine)
            actions
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 22))
    }

    @ViewBuilder private var actions: some View {
        if let text = typed {
            TextField("As printed on the page", text: Binding(get: { text }, set: { typed = $0 }))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.title3)
                .padding(12)
                .frame(minHeight: 48)
                .background(Color(.surface), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.border)))
                .accessibilityLabel("Correct \(line.name)")
            if let warning = line.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(.warning))
            }
            HStack {
                Button("Keep this value") { if onCorrect(text, false) { typed = nil } }
                    .buttonStyle(.fieldSecondary)
                Button("Cancel") { typed = nil }
                    .buttonStyle(.fieldSecondary)
            }
            if line.notOnPage != nil {
                Button("Keep it anyway, not on the page", systemImage: "hand.raised") {
                    if onCorrect(text, true) { typed = nil }
                }
                .buttonStyle(.fieldSecondary)
            }
        } else if line.decision != nil {
            Button("Change", systemImage: "arrow.uturn.backward", action: onUndo)
                .buttonStyle(.fieldSecondary)
                .accessibilityHint(line.name)
        } else {
            // #151: the values printed on the page come first, so the right one is one tap away.
            ForEach(line.choices, id: \.self) { choice in
                Button("Use \(choice.words), from the page", systemImage: "text.magnifyingglass") {
                    _ = onCorrect(choice.value, false)
                }
                .buttonStyle(.fieldPrimary)
            }
            HStack {
                Button("Confirm", systemImage: "checkmark", action: onConfirm)
                    .buttonStyle(.fieldSecondary)
                    .disabled(!line.canConfirm)
                    .accessibilityHint(line.canConfirm ? line.name : "Not found on the pages: correct it instead.")
                Button("Correct", systemImage: "pencil") { typed = "" }
                    .buttonStyle(.fieldSecondary)
                    .accessibilityHint(line.name)
            }
        }
    }
}
