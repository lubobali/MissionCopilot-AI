import SwiftUI

/// One drafted note on glass: its kind, words, who and by when, the words it came from, its problems, and
/// Confirm, Edit or Remove.
struct NoteCard: View {
    let line: DebriefReviewModel.NoteLine
    var onDecide: (NoteDecision) -> Void = { _ in }
    var onUndo: () -> Void = {}
    @State private var typed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(line.kind)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.secondaryText))
                    .textCase(.uppercase)
                Text(line.text)
                    .font(.headline)
                    .foregroundStyle(Color(.text))
                if let detail = line.detail {
                    Text(detail).font(.subheadline).foregroundStyle(Color(.secondaryText))
                }
                if let quote = line.quote {
                    Label(quote, systemImage: line.canConfirm ? "quote.opening" : "questionmark.circle")
                        .font(.subheadline.italic())
                        .foregroundStyle(Color(.secondaryText))
                }
                CardStatus(problems: line.problems, decision: line.decision)
            }
            .accessibilityElement(children: .combine)
            if let text = typed {
                CardEditor(text: text, prompt: "The note as it should be", onChange: { typed = $0 },
                           onKeep: {
                               onDecide(.edit(text))
                               typed = nil
                           }, onCancel: { typed = nil })
            } else if line.decision != nil {
                Button("Change", systemImage: "arrow.uturn.backward", action: onUndo).buttonStyle(.fieldSecondary)
            } else {
                // One row when it fits, otherwise stacked (found on the iPhone: "Con-firm", "Re-mov e").
                ViewThatFits(in: .horizontal) {
                    HStack { noteButtons }
                    VStack(alignment: .leading) { noteButtons }
                }
                .buttonStyle(.fieldSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 22))
    }
}

extension NoteCard {
    @ViewBuilder var noteButtons: some View {
        Button("Confirm", systemImage: "checkmark") { onDecide(.confirm) }
            .lineLimit(1)
            .disabled(!line.canConfirm)
            .accessibilityHint(line.canConfirm ? line.text : "Not said in the debrief: edit or remove it.")
        Button("Edit", systemImage: "pencil") { typed = line.text }
            .lineLimit(1)
        Button("Remove", systemImage: "trash") { onDecide(.remove) }
            .lineLimit(1)
    }
}

/// One heard number on glass: as heard with its unit, the words around it, its problems, Confirm or Correct.
struct NumberCard: View {
    let line: DebriefReviewModel.NumberLine
    var onConfirm: () -> Void = {}
    var onCorrect: (String) -> Bool = { _ in false }
    var onUndo: () -> Void = {}
    @State private var typed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Heard: \(line.heard)")
                    .font(.headline)
                    .foregroundStyle(Color(.text))
                Text("“…\(line.context)…”")
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryText))
                CardStatus(problems: line.problems, decision: line.decision)
            }
            .accessibilityElement(children: .combine)
            if let text = typed {
                CardEditor(text: text, prompt: "The number as it should be", onChange: { typed = $0 },
                           onKeep: { if onCorrect(text) { typed = nil } }, onCancel: { typed = nil })
            } else if line.decision != nil {
                Button("Change", systemImage: "arrow.uturn.backward", action: onUndo).buttonStyle(.fieldSecondary)
            } else {
                HStack {
                    Button("Confirm", systemImage: "checkmark", action: onConfirm)
                    Button("Correct", systemImage: "pencil") { typed = "" }
                }
                .buttonStyle(.fieldSecondary)
                .accessibilityHint(line.heard)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 22))
    }
}

/// A card's problems in words, then the officer's decision.
struct CardStatus: View {
    let problems: [String]
    let decision: String?

    var body: some View {
        ForEach(problems, id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Color(.warning))
        }
        if let decision {
            Label(decision, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.success))
        }
    }
}

/// A text field with Keep and Cancel, for an edit or a correction.
struct CardEditor: View {
    let text: String
    let prompt: String
    let onChange: (String) -> Void
    let onKeep: () -> Void
    let onCancel: () -> Void

    var body: some View {
        TextField(prompt, text: Binding(get: { text }, set: onChange), axis: .vertical)
            .autocorrectionDisabled()
            .font(.body)
            .padding(12)
            .frame(minHeight: 48)
            .background(Color(.surface), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.border)))
        HStack {
            Button("Keep", action: onKeep)
            Button("Cancel", action: onCancel)
        }
        .buttonStyle(.fieldSecondary)
    }
}
