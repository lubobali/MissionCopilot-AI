import SwiftUI

/// History (#145, step 6.7.8): every question asked on this mission, newest first, each opening its kept
/// answer as it was, with its time and "based on the sources at that time", and Ask again.
struct AskHistoryScreen: View {
    let model: AskModel
    let onAskAgain: (AskRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView("No questions yet", systemImage: "clock",
                                           description: Text("Questions you ask on this mission are kept here."))
                } else {
                    // The sheet has its own stack where every page opens by a closure, so the two kinds never mix
                    // (scripts/test_navigation.py: value destinations live only at the app's root).
                    List(model.history) { record in
                        NavigationLink {
                            KeptAnswerScreen(record: record, canAsk: !model.busy) {
                                dismiss()
                                onAskAgain(record)
                            }
                        } label: {
                            HistoryRow(record: record)
                        }
                        .listRowBackground(Color(.surface))
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .fieldScreen()
            .navigationTitle("Asked on this mission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// One kept question: its words, when, and whether it was answered.
struct HistoryRow: View {
    let record: AskRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.question)
                .font(.body)
                .foregroundStyle(Color(.text))
                .lineLimit(2)
            Text("\(AskWords.when(record.askedAt)) · \(record.answered ? "Answered" : "Not answered")")
                .font(.caption)
                .foregroundStyle(Color(.secondaryText))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A kept answer as it was, scrolling, from History.
struct KeptAnswerScreen: View {
    let record: AskRecord
    let canAsk: Bool
    let onAskAgain: () -> Void

    var body: some View {
        ScrollView { KeptAnswerView(record: record, canAsk: canAsk, onAskAgain: onAskAgain) }
            .fieldScreen()
            .navigationTitle("Kept answer")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// A kept answer without the scrolling: when it was asked, the question, the answer and its sources, and
/// Ask again.
struct KeptAnswerView: View {
    let record: AskRecord
    let canAsk: Bool
    let onAskAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(AskWords.keptAt(record.askedAt), systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(Color(.secondaryText))
            QuestionBubble(text: record.question)
            AnswerView(record: record)
                .padding(.trailing, 24)
            Button(action: onAskAgain) {
                Label("Ask again", systemImage: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(.onAccent))
            .background(Color(canAsk ? .accent : .secondaryText), in: .capsule)
            .disabled(!canAsk)
            .accessibilityHint("Asks this question again on today's data and keeps the new answer too")
        }
        .padding(16)
    }
}

/// Times in words for the Ask screens.
enum AskWords {
    /// "Nov 7 at 6:10 PM".
    static func when(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day()) + " at " + date.formatted(date: .omitted, time: .shortened)
    }

    /// "Asked Nov 7 at 6:10 PM, based on the sources at that time".
    static func keptAt(_ date: Date) -> String {
        "Asked \(when(date)), based on the sources at that time"
    }
}
