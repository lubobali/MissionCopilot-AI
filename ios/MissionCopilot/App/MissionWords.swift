import Foundation

/// What a mission row and its pack summary say (#92), in the phone's language and time zone (the tests
/// fix both). Sizes use bytes, KB or MB as the size needs; every date is a day, no time.
struct MissionWords: Sendable {
    var locale = Locale.current
    var timeZone = TimeZone.current

    /// One line of the pack summary.
    struct Fact: Equatable, Sendable {
        let label: String, value: String
    }

    func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(locale))
    }

    func day(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// The line under the status: how far, since when, until when, or why it stopped.
    func detail(_ status: MissionStatus) -> String? {
        switch status {
        case .notDownloaded(let available):
            available ? "Ready to download." : "No pack published yet. Check again later."
        case .downloading(_, 0): "Starting"
        case .downloading(let done, let total): "\(size(done)) of \(size(total))"
        case .paused(let pause): Self.text(pause)
        case .ready(let updated): "Updated \(day(updated))"
        case .expiring(_, let expires): "Expires \(day(expires))"
        case .expired(let expires): "Expired \(day(expires)). Download it again."
        case .failed(.notEnoughSpace(let needed, let available)):
            "Not enough free space: the pack needs \(size(Int(needed))), this iPhone has \(size(Int(available))) free."
        case .failed(let failure): Self.sentence(MissionRow.text(failure))
        }
    }

    static func text(_ pause: MissionPause) -> String {
        switch pause {
        case .offline: "Waiting for connection. It goes on by itself."
        case .interrupted: "Stopped. It goes on when the app is open."
        case .slowDown(let seconds): "The server is busy. It goes on in \(seconds) seconds."
        case .busy(let seconds): "The server is restarting. It goes on by itself in \(seconds) seconds."
        case .locked: "Downloaded. It is added when you unlock the app."
        }
    }

    /// The Download button's words.
    func action(_ row: MissionRow) -> String {
        switch row.status {
        case .expired: "Download again"
        case .failed: "Try again"
        case .ready, .expiring: row.updateAvailable ? "Download update" : "Download"
        default: "Download"
        }
    }

    func summary(_ pack: PackFacts) -> [Fact] {
        let files = pack.files == 1 ? "1 file" : "\(pack.files) files"
        var facts = [
            Fact(label: "Project", value: pack.projectRef),
            Fact(label: "Version", value: "\(pack.version)"),
            Fact(label: "Files", value: "\(files), \(size(pack.bytes))"),
            Fact(label: "Published", value: day(pack.published)),
            Fact(label: "Downloaded", value: day(pack.downloaded)),
            Fact(label: "Expires", value: day(pack.expires))
        ]
        if let checklist = pack.checklist {
            let questions = checklist.questions == 1 ? "1 question" : "\(checklist.questions) questions"
            let languages = checklist.french ? "English and French" : "English"
            facts.append(Fact(label: "Checklist", value: "\(questions), \(languages)"))
        }
        return facts
    }

    private static func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
}
