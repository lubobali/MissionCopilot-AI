import SwiftUI

/// Opens a mission's red flags by its id (declared at the stack's root, ContentView).
struct RedFlagsLink: Hashable, Sendable {
    let id: String
}

/// The red flags page (#134): flags first, then clear, then not checked, each with its sentence, numbers,
/// threshold, rule and source, and what it was computed from. Live while the walk is open; the stored ones
/// after the finish.
struct RedFlagsScreen: View {
    let list: MissionListModel
    let id: String
    @State private var walk: SiteWalkModel?
    @State private var cannotOpen = false

    var body: some View {
        Group {
            if let walk {
                ScrollView {
                    RedFlagsView(results: walk.flags, mission: id, stored: walk.finished != nil,
                                 words: RedFlagWords(rules: (try? .bundled()) ?? .empty, language: walk.language))
                }
            } else if cannotOpen {
                Text("The red flags cannot open. Unlock the app, and make sure the mission's pack is downloaded.")
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                Loading(text: "Checking the rules")
            }
        }
        .fieldScreen()
        .navigationTitle(walk?.language == "fr" ? "Alertes" : "Red flags")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard walk == nil else { return }
            guard let store = list.openStore, let model = try? SiteWalkModel.load(mission: id, store: store) else {
                cannotOpen = true
                return
            }
            walk = model
        }
    }
}

/// The page without the scrolling, for the screenshot tests too.
struct RedFlagsView: View {
    let results: [RedFlagResult]
    let mission: String
    let stored: Bool
    let words: RedFlagWords

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label(words.summary(results), systemImage: flagged.isEmpty ? "checkmark.shield.fill" : "flag.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(flagged.isEmpty ? .success : .danger))
                Text(words.text(stored ? (results.isEmpty ? .finishedBefore : .stored) : .live))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(.secondaryText))
                Text(words.text(.plainCode))
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryText))
            }
            .accessibilityElement(children: .combine)
            ForEach(Array(sorted.enumerated()), id: \.offset) { _, result in
                RedFlagRow(result: result, mission: mission, words: words)
            }
        }
        .padding(16)
    }

    private var flagged: [RedFlagResult] { results.filter { $0.outcome == .flag } }

    /// Flags first, then clear, then not checked; the rules file's order inside each.
    private var sorted: [RedFlagResult] {
        let rank = { (result: RedFlagResult) -> Int in
            switch result.outcome {
            case .flag: 0
            case .clear: 1
            case .notChecked: 2
            }
        }
        return results.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}

/// One result on glass: the outcome badge, the rule's title, its sentence, threshold and source, and the
/// inputs it was computed from (folded away until asked for).
struct RedFlagRow: View {
    let result: RedFlagResult
    let mission: String
    let words: RedFlagWords

    private struct Look {
        let role: ColorRole
        let icon: String
        let label: String
    }

    private var look: Look {
        switch result.outcome {
        case .flag: Look(role: .danger, icon: "flag.fill", label: words.text(.flag))
        case .clear: Look(role: .success, icon: "checkmark.circle.fill", label: words.text(.clear))
        case .notChecked: Look(role: .secondaryText, icon: "questionmark.circle", label: words.text(.notChecked))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Label(look.label, systemImage: look.icon)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color(look.role))
                    .textCase(.uppercase)
                Text(words.title(result))
                    .font(.headline)
                    .foregroundStyle(Color(.text))
                Text(words.sentence(result))
                    .font(.body)
                    .foregroundStyle(Color(.text))
                if let skipped = words.skipped(result) {
                    Text(skipped)
                        .font(.footnote)
                        .foregroundStyle(Color(.warning))
                }
                Text(words.threshold(result) + " · " + words.source(result))
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryText))
            }
            .accessibilityElement(children: .combine)
            if !result.inputs.isEmpty {
                DisclosureGroup(words.text(.computedFrom)) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(result.inputs.enumerated()), id: \.offset) { _, input in
                            Text(words.input(input, mission: mission))
                                .font(.caption.monospaced())
                                .foregroundStyle(Color(.secondaryText))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .font(.footnote.weight(.semibold))
                .tint(Color(.accent))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            // The outcome's colour as a thin edge, so a flag stands out even before it is read.
            Capsule().fill(Color(look.role)).frame(width: 4).padding(.vertical, 14)
                .accessibilityHidden(true)
        }
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 22))
    }
}

/// The red flags on a card (the workspace and the top of the walk): the summary, in the flag colour when
/// any rule flags.
struct RedFlagsCard: View {
    let results: [RedFlagResult]
    let words: RedFlagWords

    private var flagged: Bool { results.contains { $0.outcome == .flag } }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: flagged ? "flag.fill" : "checkmark.shield.fill")
                .font(.title2)
                .foregroundStyle(Color(flagged ? .danger : .success))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(words.text(.redFlags))
                    .font(.headline)
                    .foregroundStyle(Color(.text))
                Text(words.summary(results))
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
