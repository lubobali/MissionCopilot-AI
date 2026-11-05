import Foundation

/// "Before you go" (#125): whether this iPhone is ready for the field for one mission, and what to do
/// while it still has a connection. One line per item in a fixed order: the mission pack, the AI
/// assistant inside the app, the speech files for each language the mission needs, and free space.
/// Pure: the caller gathers the facts, so every case is tested without a phone.
struct BeforeYouGo: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case working  // downloading or installing: nothing to do
        case toDo  // the officer can fix it
        case cannot  // not on this iPhone or in this build: what to do instead is in the line
    }

    struct Line: Equatable, Sendable, Identifiable {
        let title: String
        let state: State
        let detail: String
        let needsConnection: Bool  // do it while still online
        var id: String { title }
    }

    /// Room for a mission's photos (3 to 5 MB each), scans and short audio, with iOS's own margin.
    static let minimumFreeBytes: Int64 = 2_000_000_000

    let lines: [Line]

    init(pack: MissionStatus, facts: PackFacts?, model: BundledModel.State,
         speech: [SpeechLanguage: SpeechFileStatus], freeBytes: Int64, words: MissionWords) {
        var lines = [Self.pack(pack, facts: facts, words: words), Self.model(model)]
        for language in SpeechLanguage.allCases {
            if let status = speech[language] { lines.append(Self.speech(language, status)) }
        }
        lines.append(Self.space(freeBytes, words: words))
        self.lines = lines
    }

    var isReady: Bool { lines.allSatisfy { $0.state == .ready } }
    var needsConnection: Bool { lines.contains(where: \.needsConnection) }

    var summary: String {
        let open = lines.filter { $0.state == .toDo || $0.state == .cannot }.count
        if open > 0 { return open == 1 ? "1 thing to do before you go" : "\(open) things to do before you go" }
        return isReady ? "Ready for the field" : "Getting ready"
    }

    private static func pack(_ status: MissionStatus, facts: PackFacts?, words: MissionWords) -> Line {
        let title = "Mission pack"
        switch status {
        case .ready:
            let until = facts.map { "Version \($0.version), works offline until \(words.day($0.expires))" }
            return Line(title: title, state: .ready, detail: until ?? "Ready for offline", needsConnection: false)
        case .expiring(_, let expires):
            return Line(title: title, state: .toDo, detail: "Expires \(words.day(expires)). Update it while online.",
                        needsConnection: true)
        case .expired(let expires):
            return Line(title: title, state: .toDo,
                        detail: "Expired \(words.day(expires)). Download it again while online.", needsConnection: true)
        case .notDownloaded(available: true):
            return Line(title: title, state: .toDo, detail: "Not downloaded. Download it while online.",
                        needsConnection: true)
        case .notDownloaded(available: false):
            return Line(title: title, state: .cannot, detail: "No pack published for this mission yet.",
                        needsConnection: false)
        case .failed:
            return Line(title: title, state: .toDo, detail: "The last download failed. Try again while online.",
                        needsConnection: true)
        case .downloading, .paused:
            return Line(title: title, state: .working, detail: words.detail(status) ?? "Downloading",
                        needsConnection: false)
        }
    }

    private static func model(_ state: BundledModel.State) -> Line {
        let title = "AI assistant"
        switch state {
        case .verified:
            return Line(title: title, state: .ready, detail: "On this iPhone, checked", needsConnection: false)
        case .notInThisBuild:
            return Line(title: title, state: .cannot, detail: "Not in this build of the app. Install the full app.",
                        needsConnection: false)
        case .refused:
            return Line(title: title, state: .cannot,
                        detail: "It failed its safety check, so it stays off. Install the app again.",
                        needsConnection: false)
        }
    }

    private static func speech(_ language: SpeechLanguage, _ status: SpeechFileStatus) -> Line {
        let title = "Speech: \(language.name)"
        switch status {
        case .installed:
            return Line(title: title, state: .ready, detail: "On this iPhone", needsConnection: false)
        case .canInstall:
            return Line(title: title, state: .toDo, detail: "Not on this iPhone. Install it while online.",
                        needsConnection: true)
        case .installing:
            return Line(title: title, state: .working, detail: "Installing", needsConnection: false)
        case .notSupported:
            return Line(title: title, state: .cannot, detail: "This iPhone cannot turn \(language.name) speech into "
                        + "text. You can type notes instead.", needsConnection: false)
        }
    }

    private static func space(_ free: Int64, words: MissionWords) -> Line {
        let amount = words.size(Int(free))
        guard free >= minimumFreeBytes else {
            return Line(title: "Free space", state: .toDo,
                        detail: "Only \(amount) free. Make room for at least 2 GB of photos and scans.",
                        needsConnection: false)
        }
        return Line(title: "Free space", state: .ready, detail: "\(amount) free", needsConnection: false)
    }
}
