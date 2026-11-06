import SwiftUI

/// The site checklist from the pack (#129), in form order: a group shows its label above its questions,
/// and only while it is shown (the bridge group, once work started).
struct ChecklistSection: View {
    let walk: SiteWalk
    let words: SiteWalkWords
    let locked: Bool
    var onAnswer: (String, String) -> Void = { _, _ in }
    var onPlace: (String) async -> Void = { _ in }
    var onPhoto: (SiteWalkModel.PhotoTarget) -> Void = { _ in }
    var thumbnail: (Int) -> UIImage? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(words.text(.checklist))
                .font(.title3.bold())
            Text(walk.form.title)
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryText))
            items(walk.form.items)
        }
    }

    private func items(_ items: [ChecklistItem]) -> AnyView {
        AnyView(ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .question(let question) where walk.isShown(question.name):
                QuestionCard(question: question, walk: walk, words: words, locked: locked, onAnswer: onAnswer,
                             onPlace: onPlace, onPhoto: onPhoto, thumbnail: thumbnail)
            case .group(let group) where group.items.contains(where: shows):
                Text(group.label.text(for: walk.language))
                    .font(.headline)
                    .padding(.top, 6)
                self.items(group.items)
            default:
                EmptyView()
            }
        })
    }

    private func shows(_ item: ChecklistItem) -> Bool {
        switch item {
        case .question(let question): walk.isShown(question.name)
        case .group(let group): group.items.contains(where: shows)
        }
    }
}

/// One question: its label in the walk's language, whether it is required, its hint, a control for its
/// type, and what is wrong with the answer, in the form's own words.
struct QuestionCard: View {
    let question: ChecklistQuestion
    let walk: SiteWalk
    let words: SiteWalkWords
    let locked: Bool
    var onAnswer: (String, String) -> Void = { _, _ in }
    var onPlace: (String) async -> Void = { _ in }
    var onPhoto: (SiteWalkModel.PhotoTarget) -> Void = { _ in }
    var thumbnail: (Int) -> UIImage? = { _ in nil }

    private var answer: String { walk.answers[question.name] ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(question.label.text(for: walk.language))
                    .font(.headline)
                if question.required, question.kind != .note {
                    Text(words.text(.required))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(.secondaryText))
                }
                if let hint = question.hint {
                    Text(hint.text(for: walk.language))
                        .font(.subheadline)
                        .foregroundStyle(Color(.secondaryText))
                }
            }
            .accessibilityElement(children: .combine)
            control.disabled(locked)
            if let problem = walk.problem(of: question.name) {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(.warning))
            }
        }
        .walkCard()
    }

    @ViewBuilder private var control: some View {
        switch question.kind {
        case .selectOne(let list):
            ChoiceButtons(choices: walk.form.choices[list] ?? [], selected: Set([answer]), language: walk.language) {
                onAnswer($0, question.name)
            }
        case .selectMultiple(let list):
            let chosen = Set(answer.split(separator: " ").map(String.init))
            ChoiceButtons(choices: walk.form.choices[list] ?? [], selected: chosen, language: walk.language) {
                onAnswer(Self.toggled($0, in: chosen, order: walk.form.choices[list] ?? []), question.name)
            }
        case .integer, .decimal, .text:
            TypedAnswer(kind: question.kind, answer: answer, words: words) { onAnswer($0, question.name) }
        case .date:
            DateAnswer(answer: answer, words: words) { onAnswer($0, question.name) }
        case .geopoint:
            PlaceAnswer(answer: answer, words: words) { await onPlace(question.name) }
        case .image:
            let seq = SiteWalkModel.photoSeq(inAnswer: answer)
            PhotoSlot(seq: seq, thumbnail: seq.flatMap(thumbnail), empty: words.text(.takePhoto), words: words) {
                onPhoto(.question(question.name))
            }
        case .note:
            EmptyView()
        }
    }

    /// A select_multiple answer is its chosen names, space separated, in the form's order.
    static func toggled(_ name: String, in chosen: Set<String>, order: [ChecklistChoice]) -> String {
        let next = chosen.symmetricDifference([name])
        return order.map(\.name).filter(next.contains).joined(separator: " ")
    }
}

/// The form's choices as large buttons: one or several can be on.
struct ChoiceButtons: View {
    let choices: [ChecklistChoice]
    let selected: Set<String>
    let language: String
    var onTap: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(choices, id: \.name) { choice in
                let chosen = selected.contains(choice.name)
                Button { onTap(choice.name) } label: {
                    Label(choice.label.text(for: language), systemImage: chosen ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(chosen ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 12)
                        .foregroundStyle(Color(chosen ? .onAccent : .text))
                        .background(Color(chosen ? .accent : .surface), in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(chosen ? .accent : .border)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
}
