import SwiftUI

/// The workspace's card for the report (#161).
struct ReportCard: View {
    let summary: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(Color(.accent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mission report")
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

/// One report sentence on glass: its words, its proof tag, and "No proof" with the reason when it has none.
struct ReportSentence: View {
    let line: ReportLine
    let number: Int
    var onProof: () -> Void = {}
    var onEdit: () -> Void = {}
    var onRemove: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(line.text)
                    .font(.body)
                    .foregroundStyle(Color(.text))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if line.checked && !line.factIds.isEmpty {
                    Button(action: onProof) { SourceNumber(number: number) }  // Ask's tag, the theme's colours
                    .accessibilityLabel("Proof \(number)")
                    .accessibilityHint("Shows the record this sentence comes from")
                }
            }
            if !line.checked || line.factIds.isEmpty {
                Label("No proof: \(line.reason ?? ReportWriter.pickFacts)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(.warning))
            }
            HStack(spacing: 16) {
                Button("Edit", systemImage: "pencil", action: onEdit)
                Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
            }
            .font(.footnote)
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 18))
    }
}

/// What a sentence stands on: each fact's record as a card.
struct ProofSheet: View {
    let line: ReportLine
    let cards: [SourceCardWords]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(line.text)
                    .font(.headline)
                    .foregroundStyle(Color(.text))
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in SourceCard(card: card) }
                Text("Every fact keeps the signed evidence it came from.")
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryText))
            }
            .padding(20)
        }
        .fieldScreen()
    }
}

/// The officer writes or changes a sentence and picks the facts it comes from; code checks it.
struct SentenceEditor: View {
    let model: ReportModel
    let section: ReportSection
    let start: ReportLine?
    let done: () -> Void
    @State private var text = ""
    @State private var picked: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section(section.title(model.language)) {
                    TextField("The sentence", text: $text, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("The facts it comes from") {
                    ForEach(model.pickable, id: \.id) { fact in
                        Button {
                            if picked.contains(fact.id) { picked.remove(fact.id) } else { picked.insert(fact.id) }
                        } label: {
                            Label(fact.words,
                                  systemImage: picked.contains(fact.id) ? "checkmark.circle.fill" : "circle")
                        }
                        .foregroundStyle(Color(.text))
                    }
                }
            }
            .navigationTitle(start == nil ? "Add a sentence" : "Edit the sentence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Check and keep") {
                        if let start {
                            model.edit(start.id, text: text, factIds: Array(picked))
                        } else {
                            model.add(section: section, text: text, factIds: Array(picked))
                        }
                        done()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                text = start?.text ?? ""
                picked = Set(start?.factIds ?? [])
            }
        }
    }
}
