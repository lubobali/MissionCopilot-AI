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
/// keyboard hides after sending. New chat starts clean; History opens every kept question.
struct AskScreen: View {
    let list: MissionListModel
    let id: String
    @State private var model: AskModel?
    @State private var cannotOpen = false
    @State private var showsHistory = false
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
                                Task { await model.send() }
                            }
                        }
                        .onChange(of: model.messages.count) {
                            withAnimation { reader.scrollTo(model.messages.last?.id, anchor: .top) }
                        }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("History", systemImage: "clock.arrow.circlepath") { showsHistory = true }
                        Button("New chat", systemImage: "square.and.pencil", action: model.newChat)
                            .disabled(model.messages.isEmpty || model.busy)
                    }
                }
                .sheet(isPresented: $showsHistory) {
                    AskHistoryScreen(model: model) { record in Task { await model.askAgain(record) } }
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
            model = AskModel(sources: MissionSources.load(mission: id, store: store),
                             keeper: .store(store, mission: id))
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
                 + "reports, and what you confirmed. Every sentence is checked against its sources. "
                 + "\(model.summary).")
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryText))
            ForEach(AskModel.examples, id: \.self) { example in
                Button { Task { await model.send(example: example) } } label: {
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
