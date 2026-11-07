import SwiftUI

/// Opens a mission's workspace by its id, so the screen reads the live row (a download's progress shows).
struct MissionLink: Hashable, Sendable {
    let id: String
}

/// A mission's workspace (#125): where the officer starts everything on site. For now: the mission, its
/// pack, and "Before you go"; each later flow adds its own part here when it works, never before.
struct MissionWorkspaceScreen: View {
    let model: MissionListModel
    let id: String
    var words = MissionWords()
    @State private var readiness = Readiness()
    @State private var walk: String?  // the site walk's progress, for its card
    @State private var flags: [RedFlagResult]?  // the red flags, for theirs (#134)

    var body: some View {
        Group {
            if let row = model.rows.first(where: { $0.id == id }) {
                ScrollView {
                    MissionWorkspace(row: row, check: readiness.check, installing: readiness.installing,
                                     problem: readiness.problem, walk: walk, flags: flags,
                                     selfTest: readiness.selfTest, selfTestLoad: readiness.selfTestLoad,
                                     words: words,
                                     onInstall: { language in Task { await readiness.install(language, for: row) } },
                                     onDownload: { model.download(row.id) },
                                     onTestModel: { Task { await readiness.testModel() } })
                }
                .refreshable { await readiness.refresh(row) }
                .task(id: row) { await readiness.refresh(row) }
                .onAppear { (walk, flags) = Self.walkCards(row, store: model.openStore) }
            } else {
                Loading(text: "Loading the mission")
            }
        }
        .fieldScreen()
        .navigationTitle("Mission")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension MissionWorkspaceScreen {
    /// The site walk's progress for its card; nil when the mission has no pack yet or the app is locked.
    static func walkProgress(_ row: MissionRow, store: MissionStore?) -> String? {
        walkCards(row, store: store).progress
    }

    /// The walk's progress and its red flags (#134), from one load of the walk.
    static func walkCards(_ row: MissionRow, store: MissionStore?) -> (progress: String?, flags: [RedFlagResult]?) {
        guard row.pack != nil, let store, let walk = try? SiteWalkModel.load(mission: row.id, store: store) else {
            return (nil, nil)
        }
        return (SiteWalkWords().progress(walk.walk.progress, finished: walk.finished), walk.flags)
    }
}

/// The workspace without the scrolling, for the screenshot tests too.
struct MissionWorkspace: View {
    let row: MissionRow
    let check: BeforeYouGo?
    let installing: SpeechLanguage?
    let problem: String?
    var walk: String?  // the site walk's progress: its card shows when there is one
    var flags: [RedFlagResult]?  // the red flags: their card shows with the walk's (#134)
    var selfTest = Readiness.SelfTest.idle  // "Test the AI assistant" (#136)
    var selfTestLoad: ModelHost.LoadNote?
    let words: MissionWords
    var onInstall: (SpeechLanguage) -> Void = { _ in }
    var onDownload: () -> Void = {}
    var onTestModel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BrandMedallion(size: 0.6)
                .environment(\.stillMarks, true)  // a quiet mark here: the home screen is where it flies
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text(row.title)
                    .font(.title2.bold())
                StatusLabel(kind: row.status.kind)
                if let reference = row.pack?.projectRef {
                    Text("Project \(reference)")
                        .font(.subheadline)
                        .foregroundStyle(Color(.secondaryText))
                }
            }
            if row.canDownload {
                Button(words.action(row), action: onDownload)
                    .buttonStyle(.fieldPrimary)
                    .accessibilityHint(row.title)
            }
            if let check {
                BeforeYouGoCard(check: check, installing: installing, problem: problem, selfTest: selfTest,
                                selfTestLoad: selfTestLoad, onInstall: onInstall, onTestModel: onTestModel)
            } else {
                Loading(text: "Checking this iPhone")
            }
            if let walk {
                NavigationLink(value: SiteWalkLink(id: row.id)) {
                    SiteWalkCard(progress: walk)
                }
                .buttonStyle(.plain)
                .accessibilityHint(row.title)
            }
            if let flags {
                NavigationLink(value: RedFlagsLink(id: row.id)) {
                    RedFlagsCard(results: flags, words: RedFlagWords(rules: (try? .bundled()) ?? .empty))
                }
                .buttonStyle(.plain)
                .accessibilityHint(row.title)
            }
            if let pack = row.pack {
                NavigationLink("Pack details") { PackSummaryView(title: row.title, pack: pack, words: words) }
                    .buttonStyle(.fieldSecondary)
            }
        }
        .padding(16)
    }
}

/// "Before you go" on glass: the summary, a line per item with its icon and words, and Install buttons.
struct BeforeYouGoCard: View {
    let check: BeforeYouGo
    let installing: SpeechLanguage?
    let problem: String?
    var selfTest = Readiness.SelfTest.idle
    var selfTestLoad: ModelHost.LoadNote?
    var onInstall: (SpeechLanguage) -> Void = { _ in }
    var onTestModel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Before you go")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.secondaryText))
                    .textCase(.uppercase)
                Label(check.summary, systemImage: check.isReady ? "checkmark.seal.fill" : "checklist")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(check.isReady ? .success : .text))
                if check.needsConnection {
                    Label("Do these while you still have a connection.", systemImage: "wifi")
                        .font(.footnote)
                        .foregroundStyle(Color(.secondaryText))
                }
            }
            .accessibilityElement(children: .combine)
            ForEach(check.lines) { line in
                ReadinessLine(line: line, installing: installing, selfTest: selfTest, selfTestLoad: selfTestLoad,
                              onInstall: onInstall, onTestModel: onTestModel)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color(.warning))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color(.surface).opacity(0.55)), in: .rect(cornerRadius: 22))
    }
}

/// One item: its icon and state in words, what it is, and what to do.
struct ReadinessLine: View {
    let line: BeforeYouGo.Line
    let installing: SpeechLanguage?
    var selfTest = Readiness.SelfTest.idle
    var selfTestLoad: ModelHost.LoadNote?
    var onInstall: (SpeechLanguage) -> Void = { _ in }
    var onTestModel: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: line.state.icon)
                .foregroundStyle(Color(line.state.color))
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(line.title) · \(line.state.words)")
                        .font(.subheadline.weight(.semibold))
                    Text(line.detail)
                        .font(.subheadline)
                        .foregroundStyle(Color(.secondaryText))
                    if line.needsConnection {
                        Label("Needs a connection", systemImage: "wifi")
                            .font(.caption)
                            .foregroundStyle(Color(.secondaryText))
                    }
                }
                .accessibilityElement(children: .combine)
                if let language = line.installs {
                    Button(installing == language ? "Installing \(language.name)" : "Install \(language.name)") {
                        onInstall(language)
                    }
                    .buttonStyle(.fieldSecondary)
                    .disabled(installing != nil)
                }
                if line.testsModel { modelTest }
            }
        }
    }
}

extension ReadinessLine {
    /// "Test the AI assistant": runs offline; the result says how fast and how many facts were right.
    @ViewBuilder var modelTest: some View {
        if case .done(let result) = selfTest {
            Label(result.words, systemImage: result.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Color(result.passed ? .success : .warning))
            if let selfTestLoad {
                Text(selfTestLoad.words)
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryText))
            }
        }
        Button(selfTest == .running ? "Testing the AI assistant" : "Test the AI assistant", action: onTestModel)
            .buttonStyle(.fieldSecondary)
            .disabled(selfTest == .running)
    }
}

extension BeforeYouGo.State {
    /// Words and an icon for every state: color is never the only signal.
    var words: String {
        switch self {
        case .ready: "Ready"
        case .working: "Getting ready"
        case .toDo: "To do"
        case .cannot: "Not available"
        }
    }

    var icon: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .working: "arrow.triangle.2.circlepath"
        case .toDo: "exclamationmark.circle.fill"
        case .cannot: "xmark.circle.fill"
        }
    }

    var color: ColorRole {
        switch self {
        case .ready: .success
        case .working: .accent
        case .toDo: .warning
        case .cannot: .danger
        }
    }
}

/// The workspace's way into the site walk: what it is and how far it got.
struct SiteWalkCard: View {
    let progress: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.walk")
                .font(.title2)
                .foregroundStyle(Color(.accent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Site walk")
                    .font(.headline)
                    .foregroundStyle(Color(.text))
                Text(progress)
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
