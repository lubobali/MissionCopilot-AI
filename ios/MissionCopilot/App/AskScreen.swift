import SwiftUI

/// Opens a mission's Ask chat by its id (declared at the stack's root, ContentView).
struct AskLink: Hashable, Sendable {
    let id: String
}

/// Ask on the workspace (#145): opens the Ask chat.
struct AskCard: View {
    let summary: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color(.accent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask the mission")
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

/// The Ask chat: the conversation scrolls, the glass input bar stays at the bottom (checked on the web: a
/// composer attached with safeAreaInset, not inside a stack), the newest message comes into view, and the
/// keyboard hides after sending. New chat starts clean.
struct AskScreen: View {
    let list: MissionListModel
    let id: String
    @State private var model: AskModel?
    @State private var cannotOpen = false
    @FocusState private var typing: Bool

    var body: some View {
        Group {
            if let model {
                ScrollViewReader { reader in
                    ScrollView { AskConversation(model: model) }
                        .scrollDismissesKeyboard(.interactively)
                        .safeAreaInset(edge: .bottom) {
                            AskComposer(model: model, typing: $typing) {
                                typing = false
                                model.ask()
                            }
                        }
                        .onChange(of: model.messages.count) {
                            withAnimation { reader.scrollTo(model.messages.last?.id, anchor: .top) }
                        }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New chat", systemImage: "square.and.pencil", action: model.newChat)
                            .disabled(model.messages.isEmpty)
                    }
                }
            } else if cannotOpen {
                Text("The mission cannot open. Unlock the app and try again.")
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                Loading(text: "Opening the mission's data")
            }
        }
        .fieldScreen()
        .navigationTitle("Ask the mission")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            guard let store = list.openStore else {
                cannotOpen = true
                return
            }
            model = AskModel(sources: MissionSources.load(mission: id, store: store))
        }
    }
}

/// The conversation without the scrolling: an introduction with example questions, then each question on the
/// right and its reply on the left.
struct AskConversation: View {
    let model: AskModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if model.messages.isEmpty { AskIntro(model: model) }
            ForEach(model.messages) { message in
                VStack(alignment: .leading, spacing: 12) {
                    QuestionBubble(text: message.question)
                    ReplyBubble(message: message)
                }
                .id(message.id)
            }
        }
        .padding(16)
    }
}

/// The first view of a clean chat: what the assistant searches, and three questions to start with.
struct AskIntro: View {
    let model: AskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(Color(.accent))
                .accessibilityHidden(true)
            Text("Ask about this mission")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color(.text))
            Text("Answers come only from this mission's own data on this iPhone, offline: the bank's records, the "
                 + "reports, and what you confirmed. \(model.summary).")
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryText))
            ForEach(AskModel.examples, id: \.self) { example in
                Button { model.ask(example: example) } label: {
                    Label(example, systemImage: "arrow.up.right")
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(.text))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            }
        }
        .padding(.top, 24)
    }
}

/// The officer's question, on the right.
struct QuestionBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.body)
                .foregroundStyle(Color(.onAccent))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.accent), in: .rect(cornerRadius: 20))
        }
        .accessibilityLabel("You asked: \(text)")
    }
}

/// The reply, on the left: the sources found in words (PR 2 turns them into a checked answer).
struct ReplyBubble: View {
    let message: AskModel.Message

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.found {
                Label("Found in this mission's data", systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.secondaryText))
                ForEach(Array(message.cards.enumerated()), id: \.offset) { _, card in SourceCard(card: card) }
            } else {
                Label(AskModel.nothingFound, systemImage: "questionmark.circle")
                    .font(.body)
                    .foregroundStyle(Color(.text))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 20))
            }
        }
        .padding(.trailing, 24)
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

/// The glass input bar: the question grows to five lines, a clear button empties it in one tap, and the round
/// send button asks.
struct AskComposer: View {
    @Bindable var model: AskModel
    var typing: FocusState<Bool>.Binding
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                TextField("Ask about this mission", text: $model.question, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)
                    .focused(typing)
                    .submitLabel(.send)
                    .onSubmit(onSend)
                if !model.question.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill", action: model.clear)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color(.secondaryText))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
            Button("Send", systemImage: "arrow.up", action: onSend)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(.onAccent))
                .frame(width: 48, height: 48)
                .background(Color(model.canAsk ? .accent : .secondaryText), in: .circle)
                .disabled(!model.canAsk)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
