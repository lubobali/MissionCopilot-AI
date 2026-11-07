import Foundation
import GRDB
import Testing
@testable import MissionCopilot

/// A debrief turned into text on the phone (#142, step 6.6.3): Apple's SpeechTranscriber reads the sealed
/// recording in its language, final results only; the transcript is sealed with the mission key and kept once
/// per engine (schema v17), append-only. Nothing heard, missing language files or a failure store nothing,
/// so the officer can try again. The engine is a fake here; the real one is proven on the iPhone.
@MainActor
struct DebriefTranscriptTests {
    let mission = "kandor-roads"

    /// An engine that answers what it is told to and counts its calls.
    final class FakeTranscriber: DebriefTranscriber, @unchecked Sendable {
        var answer: Result<String, TranscriptionProblem>
        private(set) var calls: [SpeechLanguage] = []

        init(_ answer: Result<String, TranscriptionProblem> = .success("Section 3 bridge not started.")) {
            self.answer = answer
        }

        func transcribe(_ audio: Data, language: SpeechLanguage) async throws -> String {
            calls.append(language)
            return try answer.get()
        }
    }

    private func recorded() throws -> (MissionStore, Debrief) {
        let store = try DebriefModelTests.store()
        let debrief = try store.addDebrief(try DebriefStoreTests.recording(), language: .french, to: mission,
                                           signer: SoftwareEvidenceSigner())
        return (store, debrief)
    }

    @Test func theTranscriptIsKeptSealedWithItsEngineAndReadOnce() async throws {
        let (store, debrief) = try recorded()
        let engine = FakeTranscriber()

        let first = try await store.transcribe(debrief, in: mission, engine: engine)
        let again = try await store.transcribe(debrief, in: mission, engine: engine)

        #expect(first == DebriefTranscript(text: "Section 3 bridge not started.", engine: DebriefTranscript.engine))
        #expect(again == first)
        #expect(engine.calls == [.french])  // in the debrief's own language, once
        #expect(try store.transcript(of: debrief.seq, in: mission) == first)
        let sealed = try store.store.read { try Data.fetchAll($0, sql: "SELECT sealed_text FROM debrief_transcript") }
        #expect(sealed.count == 1 && !sealed[0].contains(Data("bridge".utf8)))
    }

    @Test func nothingHeardOrAFailureStoresNothing() async throws {
        let (store, debrief) = try recorded()

        for problem in [TranscriptionProblem.nothingHeard, .languageNotInstalled, .failed] {
            await #expect(throws: problem) {
                try await store.transcribe(debrief, in: self.mission, engine: FakeTranscriber(.failure(problem)))
            }
        }
        await #expect(throws: TranscriptionProblem.nothingHeard) {
            try await store.transcribe(debrief, in: self.mission, engine: FakeTranscriber(.success("  \n")))
        }
        #expect(try store.transcript(of: debrief.seq, in: mission) == nil)
    }

    @Test func onlyADebriefCanBeTranscribed() async throws {
        let (store, _) = try recorded()
        try store.addEvidence(EvidenceChainTests.capture("site"), to: mission, signer: SoftwareEvidenceSigner())
        let photo = Debrief(seq: 2, seconds: 3, language: .english, recordedAt: Date())

        await #expect(throws: MissionStore.NotADebrief.self) {
            try await store.transcribe(photo, in: self.mission, engine: FakeTranscriber())
        }
    }

    @Test func eachProblemSaysWhatToDo() {
        #expect(TranscriptionProblem.nothingHeard.words == "No words were heard. Record again, closer to the phone.")
        #expect(TranscriptionProblem.languageNotInstalled.words
                == "This language's speech files are not on this iPhone. Install them in Before you go while online.")
        #expect(TranscriptionProblem.failed.words == "The recording could not be turned into text. Try again.")
    }

    @Test(arguments: ["UPDATE debrief_transcript SET engine = 'x'", "DELETE FROM debrief_transcript"])
    func theDatabaseKeepsTheTranscriptAsItWas(sql: String) async throws {
        let (store, debrief) = try recorded()
        _ = try await store.transcribe(debrief, in: mission, engine: FakeTranscriber())

        #expect(throws: DatabaseError.self) { try store.store.rawExecuteForTests(sql) }
    }

    @Test func theAuditNamesTheDebriefAndEngineNeverTheWords() async throws {
        let (store, debrief) = try recorded()

        _ = try await store.transcribe(debrief, in: mission, engine: FakeTranscriber())

        let events = try store.store.auditEvents().filter { $0.action == .debriefTranscribed }
        #expect(events.map(\.target) == ["\(debrief.seq) \(DebriefTranscript.engine)"])
        #expect(try store.store.verifyAudit() == .valid(count: try store.store.auditEvents().count))
    }
}
