import Foundation
import Testing
@testable import MissionCopilot

/// Grounding a debrief's notes (#142, step 6.6.6): each note's quote must be in the transcript (capitals,
/// punctuation and spaces ignored), and the app keeps where; who and by-when must be words of the quote; any
/// number or month the model wrote that was never said is a problem. A note with a problem is marked for the
/// officer, never dropped (the bakeoff models made up dates that were not said).
struct NoteGroundingTests {
    static let transcript = DebriefNotesTests.transcript

    static func note(_ quote: String, text: String = "A note.", who: String = "", byWhen: String = "",
                     kind: DebriefNote.Kind = .action) -> DebriefNote {
        DebriefNote(kind: kind, text: text, who: who, byWhen: byWhen, quote: quote)
    }

    @Test func aQuoteFromTheDebriefIsFoundWithItsPosition() throws {
        let checked = NoteGrounding.check([Self.note("the contractor shows a new work plan in two weeks",
                                                     who: "the contractor", byWhen: "in two weeks")],
                                          transcript: Self.transcript)

        let found = try #require(checked.first?.found)
        let start = Self.transcript.index(Self.transcript.startIndex, offsetBy: found.offset)
        let end = Self.transcript.index(start, offsetBy: found.length)
        #expect(Self.transcript[start..<end] == "the contractor shows a new work plan in two weeks")
        #expect(checked.first?.problems == [])
    }

    @Test func capitalsPunctuationAndSpacesDoNotMatter() throws {
        let checked = NoteGrounding.check([Self.note("SECTION 3 BRIDGE, still   not started")],
                                          transcript: Self.transcript)

        let found = try #require(checked.first?.found)
        let start = Self.transcript.index(Self.transcript.startIndex, offsetBy: found.offset)
        #expect(Self.transcript[start...].hasPrefix("Section 3 bridge still not started"))
        #expect(checked.first?.problems == [])
    }

    @Test func aQuoteThatWasNotSaidIsAProblem() {
        let checked = NoteGrounding.check([Self.note("the minister approved invoice 14"), Self.note("  ")],
                                          transcript: Self.transcript)

        #expect(checked.map(\.found) == [nil, nil])
        #expect(checked[0].problems == ["These words are not in the debrief: “the minister approved invoice 14”."])
        #expect(checked[1].problems == ["No words from the debrief were given for this note."])
    }

    @Test func aQuoteMustBeWholeWords() {
        // "ridge" is inside "bridge", and "4" inside "14": neither was said on its own.
        let checked = NoteGrounding.check([Self.note("ridge still not started"), Self.note("check invoice 1")],
                                          transcript: Self.transcript)

        #expect(checked.map(\.found) == [nil, nil])
    }

    @Test func whoAndByWhenNotSaidAreLeftOut() {
        // Found on the iPhone: the model filled "Immediate", "Ongoing", "Finance Team" that were never said.
        let checked = NoteGrounding.check([Self.note("the contractor shows a new work plan in two weeks",
                                                     who: "the road agency", byWhen: "by Friday")],
                                          transcript: Self.transcript)

        #expect(checked[0].problems == ["“the road agency” was not said here, so it is left out.",
                                        "“by Friday” was not said here, so it is left out."])
        #expect(checked[0].note.who.isEmpty && checked[0].note.byWhen.isEmpty)
        #expect(checked[0].found != nil)  // the quote itself is still found and can be confirmed
    }

    @Test func wordsTheModelGluedToNumbersStillMatch() throws {
        // Found on the iPhone: the model wrote "March15th", "Section3" and "voice14" without the space.
        let transcript = "They agreed to extend the contractor deadline to March 15th. Section 3 bridge still "
            + "not started. In voice 14, for $480,000, payments look high."
        let checked = NoteGrounding.check([Self.note("extend the contractor deadline to March15th"),
                                           Self.note("Section3 bridge still not started."),
                                           Self.note("In voice14, for $480,000, payments look high.")],
                                          transcript: transcript)

        #expect(checked.allSatisfy { $0.found != nil && $0.problems.isEmpty }, "\(checked.map(\.problems))")
        let found = try #require(checked[0].found)
        let start = transcript.index(transcript.startIndex, offsetBy: found.offset)
        #expect(transcript[start...].hasPrefix("extend the contractor deadline to March 15th"))
    }

    /// Found on the iPhone: the officer said "two weeks", the engine wrote "2 weeks", the model quoted "two".
    @Test func numberWordsAndDigitsMatchInAQuote() throws {
        let transcript = "only if the contractor shows a new work plan into 2 weeks. Section 3 bridge."
        let checked = NoteGrounding.check([Self.note("New work plan into two weeks"),
                                           Self.note("section three bridge")], transcript: transcript)

        #expect(checked.allSatisfy { $0.found != nil }, "\(checked.map(\.problems))")
        let found = try #require(checked[0].found)
        let start = transcript.index(transcript.startIndex, offsetBy: found.offset)
        #expect(transcript[start...].hasPrefix("new work plan into 2 weeks"))
    }

    @Test func aNumberOrMonthThatWasNeverSaidIsAProblem() {
        // The bakeoff's made-up dates: "14 Feb" and "15 Feb" were never in the debrief.
        let made = Self.note("extend the contractor deadline to March 15", text: "Deadline moved to 15 Feb 2027.",
                             kind: .decision)
        let said = Self.note("extend the contractor deadline to March 15", text: "Deadline moved to March 15.",
                             byWhen: "March 15", kind: .decision)

        let checked = NoteGrounding.check([made, said], transcript: Self.transcript)

        #expect(checked[0].problems == ["The number 2027 was not said in the debrief.",
                                        "The month February was not said in the debrief."])
        #expect(checked[1].problems == [])
    }

    @Test func numbersInWordsAndDigitsAreTheSame() {
        let checked = NoteGrounding.check([Self.note("a new work plan in two weeks", text: "Work plan in 2 weeks.",
                                                     byWhen: "in two weeks")],
                                          transcript: Self.transcript)

        #expect(checked[0].problems == [])
    }

    @Test func frenchMonthsCountToo() {
        let transcript = "Le délai est prolongé jusqu'au 15 mars."
        let checked = NoteGrounding.check([
            Self.note("prolongé jusqu'au 15 mars", text: "Délai au 15 mars."),
            Self.note("prolongé jusqu'au 15 mars", text: "Délai au 15 février.")
        ], transcript: transcript)

        #expect(checked[0].problems == [])
        #expect(checked[1].problems == ["The month February was not said in the debrief."])
    }
}
