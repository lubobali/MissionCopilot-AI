import Foundation
import Testing
@testable import MissionCopilot

/// The agreed actions from the last mission (#129, step 6.2.2): what the site walk checks first. Read
/// from the pack's section (already checked against the schema at import), each keyed by its text,
/// and overdue when its deadline passed before the walk and nobody has seen it done.
struct AgreedActionsTests {
    static let section = Data("""
        {"actions": [
          {"action": "Start the Section 3 bridge works", "deadline": "2026-07-31", "responsible": "Contractor",
           "status": "Not started"},
          {"action": "Submit a revised work plan", "deadline": "2026-07-15", "responsible": "Contractor",
           "status": "Ongoing"},
          {"action": "Review payment certification before the next invoice", "deadline": "2026-09-30",
           "responsible": "Ministry", "status": "Completed"}
         ],
         "mission": "Supervision mission, May 2026",
         "summary": "The contractor committed to start the Section 3 bridge by July 2026."}
        """.utf8)

    let utc = TimeZone.gmt
    func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: "\(text)T12:00:00Z") ?? .distantPast }

    @Test func theSectionReadsWithEveryActionInItsOrder() throws {
        let actions = try AgreedActions.read(Self.section)

        #expect(actions.mission == "Supervision mission, May 2026")
        #expect(actions.summary.hasPrefix("The contractor committed"))
        #expect(actions.actions.map(\.responsible) == ["Contractor", "Contractor", "Ministry"])
        #expect(actions.actions.map(\.status) == [.notStarted, .ongoing, .completed])
        #expect(actions.actions[0].deadline == "2026-07-31")
    }

    @Test func eachActionIsKeyedByTheSHA256OfItsText() throws {
        // The pack has no ids; the text is what was agreed, so its hash names the check.
        let first = try AgreedActions.read(Self.section).actions[0]

        // shasum -a 256 of the text, computed outside Swift: a hash of a public sentence, not a secret
        let expected = "53f6e638bcf6652730f87083af0ae88d4238c7f5dee913cda2276af4dd3261d4"  // gitleaks:allow
        #expect(first.key == expected)
        #expect(first.key == AgreedActions.Action.key(for: "Start the Section 3 bridge works"))
        #expect(first.key.allSatisfy { "0123456789abcdef".contains($0) })
        let keys = try AgreedActions.read(Self.section).actions.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    @Test func anActionIsOverdueWhenItsDeadlinePassedBeforeTheWalk() throws {
        let bridge = try AgreedActions.read(Self.section).actions[0]

        #expect(bridge.isOverdue(on: day("2026-11-10"), seen: nil, timeZone: utc))
        #expect(!bridge.isOverdue(on: day("2026-07-31"), seen: nil, timeZone: utc), "due that day, not late yet")
        #expect(!bridge.isOverdue(on: day("2026-07-30"), seen: nil, timeZone: utc))
    }

    @Test func anActionSeenDoneOrMarkedCompletedIsNotOverdue() throws {
        let actions = try AgreedActions.read(Self.section).actions
        let walk = day("2026-11-10")

        #expect(!actions[0].isOverdue(on: walk, seen: .done, timeZone: utc))
        #expect(actions[0].isOverdue(on: walk, seen: .inProgress, timeZone: utc))
        #expect(actions[0].isOverdue(on: walk, seen: .couldNotCheck, timeZone: utc))
        #expect(!actions[2].isOverdue(on: walk, seen: nil, timeZone: utc), "the pack says completed")
    }

    @Test func theWalksDayIsTheOfficersOwnCalendarDay() throws {
        // 23:30 on Jul 31 in Chicago is already Aug 1 in UTC: the officer's day decides.
        let bridge = try AgreedActions.read(Self.section).actions[0]
        let lateEvening = try #require(ISO8601DateFormatter().date(from: "2026-08-01T04:30:00Z"))
        let chicago = try #require(TimeZone(identifier: "America/Chicago"))

        #expect(!bridge.isOverdue(on: lateEvening, seen: nil, timeZone: chicago))
        #expect(bridge.isOverdue(on: lateEvening, seen: nil, timeZone: utc))
    }

    @Test func aSectionThatIsNotTheContractIsAnError() {
        #expect(throws: (any Error).self) { try AgreedActions.read(Data("{\"actions\": 3}".utf8)) }
    }
}
