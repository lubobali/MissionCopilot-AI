import Foundation
import Testing
@testable import MissionCopilot

/// Debrief note fixtures (#142). Since #152 code writes the notes (DebriefCodeNotesTests); these drafted notes
/// stay as input for the grounding and storing tests, which check any note, whoever wrote it.
struct DebriefNotesTests {
    /// The bakeoff's T1 debrief (docs/bakeoff.md), as a transcript.
    static let transcript = """
        Just met the deputy minister of transport and the road agency director. They agreed to extend the \
        contractor deadline to March 15 but only if the contractor shows a new work plan in two weeks. Section 3 \
        bridge still not started. The payments look high compared to what we saw on the road, need to check \
        invoice 14.
        """

    static let answer = #"""
        {"notes":[
         {"kind":"decision","text":"Contractor deadline extended to March 15 if a new work plan comes.",
          "who":"","byWhen":"March 15","quote":"extend the contractor deadline to March 15"},
         {"kind":"action","text":"Contractor shows a new work plan.","who":"the contractor","byWhen":"in two weeks",
          "quote":"the contractor shows a new work plan in two weeks"},
         {"kind":"risk","text":"Payments look high compared to the work on the road.","who":"","byWhen":"",
          "quote":"The payments look high compared to what we saw on the road"}]}
        """#

    static var notes: [DebriefNote] {
        get throws { try JSONDecoder().decode([String: [DebriefNote]].self, from: Data(answer.utf8))["notes"] ?? [] }
    }

    @Test func theFixturesAreThreeNotes() throws {
        #expect(try Self.notes.map(\.kind) == [.decision, .action, .risk])
    }
}
