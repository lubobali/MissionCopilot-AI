import SwiftUI

/// The agreed actions from the last mission (#129): what a site walk checks first. Each says who must do
/// it by when, and whether it is late; the officer picks what was seen and may add a note.
struct AgreedActionsSection: View {
    let walk: SiteWalk
    let words: SiteWalkWords
    let locked: Bool
    var onCheck: (ActionSeen, String?, String) -> Void = { _, _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(words.text(.agreedActions))
                    .font(.title3.bold())
                Text(walk.actions.mission)
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryText))
                if words.language == "fr" {
                    Text(words.text(.actionsAsGiven))
                        .font(.footnote)
                        .foregroundStyle(Color(.secondaryText))
                }
            }
            ForEach(walk.actions.actions, id: \.key) { action in
                ActionCard(action: action, check: walk.checks[action.key], words: words, locked: locked,
                           overdue: action.isOverdue(on: Date(), seen: walk.checks[action.key]?.seen,
                                                     timeZone: words.timeZone)) { seen, note in
                    onCheck(seen, note, action.key)
                }
            }
        }
    }
}

/// One agreed action: what was agreed, who and by when, four ways it can have been seen, and a note.
struct ActionCard: View {
    let action: AgreedActions.Action
    let check: ActionCheck?
    let words: SiteWalkWords
    let locked: Bool
    let overdue: Bool
    var onCheck: (ActionSeen, String?) -> Void = { _, _ in }
    @State private var note = ""
    @FocusState private var writing: Bool

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.action)
                    .font(.headline)
                Text(words.due(action))
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryText))
                if overdue {
                    Label(words.text(.overdue), systemImage: "clock.badge.exclamationmark.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.warning))
                }
            }
            .accessibilityElement(children: .combine)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ActionSeen.allCases, id: \.self) { seen in
                    SeenButton(seen: seen, words: words, selected: check?.seen == seen) {
                        onCheck(seen, note.isEmpty ? nil : note)
                    }
                }
            }
            .disabled(locked)
            TextField(words.text(.note), text: $note, axis: .vertical)
                .lineLimit(1...4)
                .padding(12)
                .background(Color(.surface), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.border)))
                .focused($writing)
                .toolbar {
                    if writing {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button(words.language == "fr" ? "OK" : "Done") { writing = false }
                                .font(.headline)
                        }
                    }
                }
                .disabled(locked || check == nil)
                .onChange(of: writing) { _, isWriting in
                    // Saved when the officer leaves the note, never on every letter (one audit event).
                    if !isWriting, let seen = check?.seen, note != (check?.note ?? "") { onCheck(seen, note) }
                }
            if check == nil, !locked {
                Text(words.text(.pickFirst))
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryText))
            }
        }
        .walkCard()
        .onAppear { note = check?.note ?? "" }
    }
}

/// One way an action can have been seen: a large target with an icon and words, filled when chosen.
struct SeenButton: View {
    let seen: ActionSeen
    var words = SiteWalkWords()
    let selected: Bool
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Label(words.seen(seen), systemImage: SiteWalkWords.icon(seen))
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 12)
                .foregroundStyle(Color(selected ? .onAccent : .text))
                .background(Color(selected ? .accent : .surface), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(selected ? .accent : .border)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
