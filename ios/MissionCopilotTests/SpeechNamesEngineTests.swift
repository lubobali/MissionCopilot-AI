import Foundation
import Testing
@testable import MissionCopilot

/// The debrief engine with the mission's names (#153, decided from Lubo's voice: dictation with the names made
/// 19% word errors against 29% and heard "$480,000" where the old engine heard "180,000 hours"). Each debrief is
/// read with that mission's names; the words the engine was not sure of are kept with the transcript and shown
/// underlined; a heard word that sounds like a name is offered as that name after the recording.
@MainActor
struct SpeechNamesEngineTests {
    let mission = PackDownloaderTests.mission

    /// The engine is given the mission's own names, from its pack (universal: no list per mission).
    @Test func eachDebriefIsReadWithItsMissionsNames() async throws {
        let store = try await AskOpeningTests.store().0
        let debrief = try store.addDebrief(try DebriefStoreTests.recording(), language: .english, to: mission,
                                           signer: SoftwareEvidenceSigner())
        let engine = DebriefTranscriptTests.FakeTranscriber(.success("Condor road visit."))
        engine.unsure = [TextSpan(offset: 0, length: 6)]

        let transcript = try await store.transcribe(debrief, in: mission, engine: engine)

        #expect(engine.names.first?.contains("Kandor") == true, "\(engine.names)")
        #expect(transcript.engine == DebriefTranscript.engine)
        #expect(DebriefTranscript.engine == "apple-dictation-names-1")
        #expect(transcript.unsure == [TextSpan(offset: 0, length: 6)])
        #expect(try store.transcript(of: debrief.seq, in: mission) == transcript)
    }

    /// A transcript kept by the old engine (before #153) is still read, and has no unsure words.
    @Test func anOlderEnginesTranscriptIsStillRead() throws {
        let old = #"{"text":"Counter route visit.","engine":"apple-speechtranscriber-1"}"#
        let decoded = try JSONDecoder().decode(DebriefTranscript.self, from: Data(old.utf8))

        #expect(decoded.text == "Counter route visit.")
        #expect(decoded.unsure.isEmpty)
        #expect(DebriefTranscript.readable.contains("apple-speechtranscriber-1"))
        #expect(DebriefTranscript.readable.first == DebriefTranscript.engine)
    }

    /// The engine's words with their confidence become the text and the spans under 0.5.
    @Test func wordsUnderHalfConfidenceAreUnsure() {
        let heard = HeardText.from([("Condor", 0.31), (" road", 0.92), (" visit.", nil), (" Okafor", 0.49),
                                    (" came.", 0.5)])

        #expect(heard.text == "Condor road visit. Okafor came.")
        #expect(heard.unsure == [TextSpan(offset: 0, length: 6), TextSpan(offset: 19, length: 6)])
        #expect(HeardText.unsureBelow == 0.5)
    }

    /// Spaces around a word are not part of what is underlined.
    @Test func anUnsureSpanHoldsOnlyTheWord() {
        let heard = HeardText.from([("  Candor ", 0.2)])
        #expect(heard.unsure == [TextSpan(offset: 2, length: 6)])
    }

    /// After the recording, the notes screen offers "Condor -> Kandor"; accepting fixes the notes that hold the
    /// word (the officer's edit); the transcript stays as heard.
    @Test func aSuggestedNameFixesTheNotesWhenAccepted() async throws {
        let store = try await AskOpeningTests.store().0
        let debrief = try store.addDebrief(try DebriefStoreTests.recording(), language: .english, to: mission,
                                           signer: SoftwareEvidenceSigner())
        _ = try await store.transcribe(debrief, in: mission, engine: DebriefTranscriptTests.FakeTranscriber(
            .success("Risk, the Condor bridge is late. Action, the contractor will send a plan. "
                     + "Risk, Condor roads are stuck.")))
        let review = DebriefReviewModel(mission: mission, debrief: debrief, store: store, contracts: nil)
        await review.draft()

        #expect(review.suggestions == [CloseNames.Suggestion(heard: "Condor", name: "Kandor")])
        review.decide(note: 2, .confirm)  // decided before: kept as it is
        review.accept(review.suggestions[0])

        #expect(review.suggestions.isEmpty)
        #expect(review.notes[0].decision == "Edited: Risk, the Kandor bridge is late.")
        #expect(review.notes[1].decision == nil)
        #expect(review.notes[2].decision == "Confirmed")
        #expect(try store.transcript(of: debrief.seq, in: mission)?.text.contains("Condor") == true)
    }
}
