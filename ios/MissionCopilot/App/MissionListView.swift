import SwiftUI

/// The missions screen (#92): the hub's list, refreshed on open and on pull, or what is missing first.
struct MissionListScreen: View {
    let hub: MissionsHub
    @State private var problem: MissionsHub.Problem?

    var body: some View {
        Group {
            if let model = hub.model {
                MissionListView(rows: model.rows, message: model.message, onDownload: model.download)
                    .refreshable { await model.refresh() }
            } else if let notice = hub.shredNotice {
                Text(notice)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .fieldScreen()
            } else if let problem {
                Text(MissionsHub.text(problem))
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .fieldScreen()
            } else {
                // Never empty (#94): an empty screen has no size, so its .task never runs and it stays blank.
                Loading(text: "Loading missions")
            }
        }
        .navigationTitle("Missions")
        .task {
            switch hub.open() {
            case .success(let model): await model.refresh()
            case .failure(let error): problem = error
            }
        }
    }
}

/// The list itself, drawn from rows only, in a scrolling frame.
struct MissionListView: View {
    let rows: [MissionRow]
    let message: String?
    var words = MissionWords()
    var onDownload: (String) -> Void = { _ in }

    var body: some View {
        ScrollView {
            MissionCards(rows: rows, message: message, words: words, onDownload: onDownload)
        }
        .fieldScreen()
    }
}

/// What the list shows, without the scrolling (the screenshot tests draw this: ImageRenderer draws no
/// ScrollView).
struct MissionCards: View {
    let rows: [MissionRow]
    let message: String?
    let words: MissionWords
    var onDownload: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(Color(.warning))
            }
            if rows.isEmpty, message == nil {
                Text("No missions for this iPhone yet. Pull down to check again.")
                    .foregroundStyle(Color(.secondaryText))
            }
            ForEach(rows) { row in
                MissionCard(row: row, words: words) { onDownload(row.id) }
            }
        }
        .padding(16)
    }
}

/// One mission: title, status in icon and words, how far or since when, a note, and its actions.
struct MissionCard: View {
    let row: MissionRow
    let words: MissionWords
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.title)
                .font(.headline)
            StatusLabel(kind: row.status.kind)
            if case .downloading(let done, let total) = row.status, total > 0 {
                ProgressBar(fraction: Double(done) / Double(total))
            }
            if let detail = words.detail(row.status) {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryText))
            }
            if let note = row.note ?? (row.updateAvailable ? "A newer pack is on the server." : nil) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Color(.warning))
            }
            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.surface), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(.border)))
    }

    @ViewBuilder private var actions: some View {
        if row.canDownload {
            Button(words.action(row), action: onDownload)
                .buttonStyle(.fieldPrimary)
                .accessibilityHint(row.title)
        }
        if let pack = row.pack {
            NavigationLink("Pack details") { PackSummaryView(title: row.title, pack: pack, words: words) }
                .buttonStyle(.fieldSecondary)
                .accessibilityHint(row.title)
        }
    }
}

/// The pack on the phone in short: which project, which version, how many files, and its dates.
struct PackSummaryView: View {
    let title: String
    let pack: PackFacts
    var words = MissionWords()

    var body: some View {
        ScrollView {
            PackSummary(title: title, pack: pack, words: words)
        }
        .fieldScreen()
        .navigationTitle("Pack")
    }
}

/// The summary without the scrolling, for the screenshot tests too.
struct PackSummary: View {
    let title: String
    let pack: PackFacts
    let words: MissionWords

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
            ForEach(words.summary(pack), id: \.label) { fact in
                FactRow(fact: fact)
                Divider().overlay(Color(.border))
            }
            Text("Kept encrypted on this iPhone. It works without a connection until it expires.")
                .font(.footnote)
                .foregroundStyle(Color(.secondaryText))
        }
        .padding(16)
    }
}

/// A label and its value side by side, or the label above the value at the accessibility text sizes, so
/// neither is broken in the middle of a word.
struct FactRow: View {
    let fact: MissionWords.Fact
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        Group {
            if size.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.label).foregroundStyle(Color(.secondaryText))
                    Text(fact.value)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LabeledContent(fact.label, value: fact.value)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// How far a download is, in the theme colors (drawn from shapes, so the screenshot tests can draw it).
struct ProgressBar: View {
    let fraction: Double
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 6

    var body: some View {
        Capsule()
            .fill(Color(.border))
            .overlay(alignment: .leading) {
                GeometryReader { space in
                    Capsule()
                        .fill(Color(.accent))
                        .frame(width: space.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)  // the words under it say the same
    }
}
