import Foundation
import Testing
@testable import MissionCopilot

/// Debrief to notes (#142, step 6.6.5): the transcript goes through the one model door (FieldModel) with a notes
/// schema: decisions, actions (who, what, by when) and risks, each with the exact words it came from. At most 10.
/// Empty, too long, stopped, refused or no notes goes to the officer, who can write the notes instead.
struct DebriefNotesTests {
    typealias FakeEngine = FieldModelTests.FakeEngine

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

    @Test func theTaskAsksForQuotedNotesWithTheNotesSchema() throws {
        let task = DebriefExtraction.task("TRANSCRIPT")

        // Found on the iPhone: with a "Debrief:" label the model copied it into a quote; the text comes alone.
        #expect(task.prompt.hasSuffix("\n\nTRANSCRIPT"))
        #expect(!task.prompt.contains("Debrief:"))
        #expect(task.prompt.contains("exact words"))
        #expect(task.schema == DebriefNote.schema)
        #expect(task.maxTokens == 512)
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(task.schema.utf8)) as? [String: Any])
        let notes = try #require((schema["properties"] as? [String: Any])?["notes"] as? [String: Any])
        #expect(notes["maxItems"] as? Int == 10)
        let item = try #require(notes["items"] as? [String: Any])
        #expect(item["required"] as? [String] == ["kind", "text", "who", "byWhen", "quote"])
        #expect(item["additionalProperties"] as? Bool == false)
    }

    @Test func aValidAnswerBecomesNotesToCheck() async throws {
        let engine = FakeEngine(answer: Self.answer)

        let outcome = await DebriefExtraction.extract(Self.transcript, model: FieldModel(engine: engine))

        guard case .notes(let notes) = outcome else {
            Issue.record("expected notes, got \(outcome)")
            return
        }
        #expect(notes.map(\.kind) == [.decision, .action, .risk])
        #expect(notes[1] == DebriefNote(kind: .action, text: "Contractor shows a new work plan.",
                                        who: "the contractor", byWhen: "in two weeks",
                                        quote: "the contractor shows a new work plan in two weeks"))
        #expect(await engine.asked.first?.prompt.contains("invoice 14") == true)
    }

    @Test func moreThanTenNotesKeepsTheFirstTen() async {
        let note = #"{"kind":"risk","text":"r","who":"","byWhen":"","quote":"road"}"#
        let many = #"{"notes":["# + Array(repeating: note, count: 12).joined(separator: ",") + "]}"

        let model = FieldModel(engine: FakeEngine(answer: many))
        let outcome = await DebriefExtraction.extract(Self.transcript, model: model)

        guard case .notes(let notes) = outcome else {
            Issue.record("expected notes")
            return
        }
        #expect(notes.count == 10)
    }

    @Test func whatTheModelCannotDoGoesToTheOfficer() async {
        struct Missing: ModelEngine {
            func generate(_ request: ModelRequest) async throws -> String { throw ModelUnavailable.couldNotLoad }
        }
        let quick = TimeLimit(.milliseconds(100))
        let cases: [(model: FieldModel, why: DebriefExtraction.Why)] = [
            (FieldModel(engine: FakeEngine(answer: #"{"notes":[]}"#)), .noNotes),
            (FieldModel(engine: FakeEngine(answer: "Here are the notes.")), .notUsable),
            (FieldModel(engine: FakeEngine(answer: Self.answer, delay: .seconds(5)), limit: quick), .stopped),
            (FieldModel(engine: Missing()), .unavailable(.couldNotLoad))
        ]

        for (model, why) in cases {
            #expect(await DebriefExtraction.extract(Self.transcript, model: model) == .toOfficer(why), "\(why)")
        }
        let blank = await DebriefExtraction.extract(" \n ", model: FieldModel(engine: FakeEngine(answer: Self.answer)))
        #expect(blank == .toOfficer(.noText))
    }

    @Test func aTranscriptTooLongNeverReachesTheModel() async {
        let engine = FakeEngine(answer: Self.answer)
        let long = String(repeating: "word ", count: FieldModel.maxInputCharacters / 5 + 1)

        let outcome = await DebriefExtraction.extract(long, model: FieldModel(engine: engine))

        guard case .toOfficer(.tooLong) = outcome else {
            Issue.record("expected too long, got \(outcome)")
            return
        }
        #expect(await engine.asked.isEmpty)
    }

    @Test func everyReasonSaysWhatToDo() {
        let reasons: [DebriefExtraction.Why] = [.noText, .tooLong(characters: 21_000), .stopped, .notUsable, .noNotes,
                                                .unavailable(.notInThisBuild), .unavailable(.failedCheck),
                                                .unavailable(.couldNotLoad)]

        #expect(Set(reasons.map(\.words)).count == reasons.count)
        #expect(reasons.allSatisfy { $0.words.hasSuffix(".") })
        #expect(DebriefExtraction.Why.noNotes.words.contains("Write the notes yourself"))
    }
}
