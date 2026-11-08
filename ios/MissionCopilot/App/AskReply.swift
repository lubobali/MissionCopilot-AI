import SwiftUI

/// The reply, on the left (#145, step 6.7.8): while the assistant works, it says so; then the checked answer,
/// each sentence with numbered tags for the sources it cites (tap one to see what it says), or why there is no
/// answer with the sources found. What is shown is the answer as it was kept.
struct ReplyBubble: View {
    let message: AskModel.Message

    var body: some View {
        Group {
            if let record = message.record {
                AnswerView(record: record, notKept: message.notKept)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading this mission's data on this iPhone…")
                        .font(.subheadline)
                        .foregroundStyle(Color(.secondaryText))
                }
                .padding(16)
                .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 20))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.trailing, 24)
    }
}

/// A kept answer: its sentences with source tags and the sources they cite, or why there is none with the
/// sources found.
struct AnswerView: View {
    let record: AskRecord
    var notKept = false
    @State private var shown: MissionSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if record.answered {
                VStack(alignment: .leading, spacing: 12) {
                    Label("From this mission's data, checked", systemImage: "checkmark.seal")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.secondaryText))
                    ForEach(Array(record.sentences.enumerated()), id: \.offset) { _, sentence in
                        SentenceRow(sentence: sentence, numbers: numbers, sources: cited) { shown = $0 }
                    }
                    if !record.leftOut.isEmpty {
                        Text(leftOutWords)
                            .font(.caption)
                            .foregroundStyle(Color(.secondaryText))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 20))
                ForEach(cited, id: \.id) { source in
                    Button { shown = source } label: { CitedRow(number: numbers[source.id] ?? 0, source: source) }
                        .buttonStyle(.plain)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(record.why?.words ?? AskResult.Why.dataDoesNotSay.words, systemImage: "questionmark.circle")
                        .font(.body)
                        .foregroundStyle(Color(.text))
                    // Why the checks held the answer back (found on the iPhone: nobody could tell).
                    if record.why == .noneBacked {
                        ForEach(reasons, id: \.self) { reason in
                            Label(reason, systemImage: "xmark.seal")
                                .font(.caption)
                                .foregroundStyle(Color(.secondaryText))
                        }
                    }
                }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 20))
                ForEach(Array(SourceWords.cards(record.found).enumerated()), id: \.offset) { _, card in
                    SourceCard(card: card)
                }
            }
            if notKept {
                Label("This answer could not be kept in History.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryText))
            }
        }
        .sheet(item: $shown) { source in
            SourceSheet(number: numbers[source.id] ?? 0, source: source)
                .presentationDetents([.medium, .large])
        }
    }

    /// The sources the shown sentences cite, numbered in the order first cited.
    private var cited: [MissionSource] {
        var seen: [String] = []
        for id in record.sentences.flatMap(\.sources) where !seen.contains(id) { seen.append(id) }
        return seen.compactMap { id in record.found.first { $0.id == id } }
    }

    private var numbers: [String: Int] {
        Dictionary(uniqueKeysWithValues: cited.enumerated().map { ($1.id, $0 + 1) })
    }

    /// The checks' reasons, each once, in order.
    private var reasons: [String] {
        record.leftOut.map(\.reason).reduce(into: []) { all, reason in if !all.contains(reason) { all.append(reason) } }
    }

    private var leftOutWords: String {
        let count = record.leftOut.count
        return count == 1 ? "1 sentence was left out: the mission's data does not back it."
            : "\(count) sentences were left out: the mission's data does not back them."
    }
}

/// One sentence and the numbered tags of the sources it cites; a tag opens what it cites.
struct SentenceRow: View {
    let sentence: AnswerSentence
    let numbers: [String: Int]
    let sources: [MissionSource]
    let onTag: (MissionSource) -> Void
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        // The tags end the sentence; at the largest text sizes they go under it.
        let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .lastTextBaseline, spacing: 8))
        layout {
            Text(sentence.text)
                .font(.body)
                .foregroundStyle(Color(.text))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(sources.filter { sentence.sources.contains($0.id) }, id: \.id) { source in
                    Button { onTag(source) } label: { SourceNumber(number: numbers[source.id] ?? 0) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Source \(numbers[source.id] ?? 0): \(SourceWords.card(source).title)")
                }
            }
        }
    }
}

/// A source's number in a small accent circle.
struct SourceNumber: View {
    let number: Int
    @ScaledMetric(relativeTo: .caption) private var side = 24.0

    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(.onAccent))
            .padding(4)
            .frame(minWidth: side, minHeight: side)
            .background(Color(.accent), in: .circle)
    }
}

/// A cited source under the answer: its number, title and where it came from; tap to read it.
struct CitedRow: View {
    let number: Int
    let source: MissionSource

    var body: some View {
        let card = SourceWords.card(source)
        HStack(alignment: .top, spacing: 12) {
            SourceNumber(number: number)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(.text))
                Text(card.place)
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryText))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color(.secondaryText))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows what this source says")
    }
}

/// What a tag cites: the source in words, as it was when the question was asked.
struct SourceSheet: View {
    let number: Int
    let source: MissionSource

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Source \(number)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.secondaryText))
                SourceCard(card: SourceWords.card(source))
                Text("As it was when you asked.")
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryText))
            }
            .padding(20)
        }
        .fieldScreen()
    }
}

/// One source on glass: its title, a few lines, and where it came from.
struct SourceCard: View {
    let card: SourceCardWords

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title)
                .font(.headline)
                .foregroundStyle(Color(.text))
            ForEach(card.lines, id: \.self) { line in
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(Color(.text))
            }
            Label(card.place, systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(Color(.secondaryText))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}
