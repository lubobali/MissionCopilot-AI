import SwiftUI

/// Opens a mission's Ask page by its id (declared at the stack's root, ContentView).
struct AskLink: Hashable, Sendable {
    let id: String
}

/// Ask on the workspace (#145): how much mission data the phone holds; opens the Ask page.
struct AskCard: View {
    let summary: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "text.magnifyingglass")
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

/// The Ask page: a question, then the mission's sources that match it, each with where it came from.
struct AskScreen: View {
    let list: MissionListModel
    let id: String
    @State private var model: AskModel?
    @State private var cannotOpen = false

    var body: some View {
        Group {
            if let model {
                ScrollView { AskView(model: model) }
            } else if cannotOpen {
                Text("The mission cannot open. Unlock the app and try again.")
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                Loading(text: "Opening the mission's data")
            }
        }
        .fieldScreen()
        .navigationTitle("Ask")
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

/// The page without the scrolling, for the screenshot tests too.
struct AskView: View {
    @Bindable var model: AskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ask about this mission")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(.text))
                Text("Searched on this iPhone, offline, in the mission's own data: the bank's records, the reports, "
                     + "and what you confirmed. \(model.summary).")
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryText))
            }
            .accessibilityElement(children: .combine)
            TextField("Was the Section 3 bridge started?", text: $model.question, axis: .vertical)
                .font(.body)
                .padding(12)
                .frame(minHeight: 48)
                .background(Color(.surface), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.border)))
                .submitLabel(.search)
                .onSubmit(model.ask)
            Button("Ask", systemImage: "magnifyingglass", action: model.ask)
                .buttonStyle(.fieldPrimary)
                .disabled(!model.canAsk)
            switch model.state {
            case .waiting:
                EmptyView()
            case .nothingFound:
                Label(AskModel.nothingFound, systemImage: "questionmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryText))
            case .found:
                Text("Sources found")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.secondaryText))
                    .textCase(.uppercase)
                ForEach(model.results) { SourceCard(result: $0) }
            }
        }
        .padding(16)
    }
}

/// One source on glass: its kind, title, where it came from, and its words.
struct SourceCard: View {
    let result: AskModel.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.kind)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.accent))
                .textCase(.uppercase)
            Text(result.title)
                .font(.headline)
                .foregroundStyle(Color(.text))
            Text(result.text)
                .font(.subheadline)
                .foregroundStyle(Color(.text))
                .lineLimit(8)
            Label(result.place, systemImage: "link")
                .font(.caption)
                .foregroundStyle(Color(.secondaryText))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}
