import Foundation
import GRDB
import Testing
@testable import MissionCopilot

/// A debrief kept (#142, step 6.6.2, decided B): the recording is signed evidence (kind audio) sealed with
/// the mission key, recorded with its length and language (schema v16), append-only, gone only with its
/// mission. The temporary file is deleted once its sealed copy is stored.
@MainActor
struct DebriefStoreTests {
    let mission = "kandor-roads"

    private func store() throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        return store
    }

    /// A recorded file in the temporary folder, as the microphone leaves it.
    static func recording(seconds: Double = 42, bytes: Data = Data("fake m4a audio bytes".utf8)) throws -> Recording {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("debrief-\(UUID().uuidString).m4a")
        try bytes.write(to: file)
        return Recording(file: file, seconds: seconds)
    }

    @Test func aRecordingIsSignedAudioEvidenceWithItsLengthAndLanguage() throws {
        let store = try store()
        let recording = try Self.recording()

        let debrief = try store.addDebrief(recording, language: .french, to: mission, signer: SoftwareEvidenceSigner(),
                                           now: SiteWalkTests.walkDay)

        let payloads = try store.evidence(in: mission).map {
            try JSONDecoder().decode(EvidencePayload.self, from: $0.payload)
        }
        #expect(payloads.map(\.kind) == [.audio])
        #expect(payloads.first?.location == nil)
        #expect(debrief == Debrief(seq: payloads[0].seq, seconds: 42, language: .french,
                                   recordedAt: SiteWalkTests.walkDay))
        #expect(try store.debriefs(in: mission) == [debrief])
        #expect(try store.evidenceFile(in: mission, seq: debrief.seq) == Data("fake m4a audio bytes".utf8))
    }

    @Test func theAudioIsSealedAndTheTemporaryFileIsGone() throws {
        let store = try store()
        let recording = try Self.recording()

        try store.addDebrief(recording, language: .english, to: mission, signer: SoftwareEvidenceSigner())

        #expect(!FileManager.default.fileExists(atPath: recording.file.path))
        let sealed = try store.store.read { try Data.fetchAll($0, sql: "SELECT sealed_file FROM evidence") }
        #expect(sealed.count == 1 && !sealed[0].contains(Data("fake m4a".utf8)))
    }

    @Test func debriefsComeBackInTheOrderRecorded() throws {
        let store = try store()
        let now = Date(timeIntervalSince1970: 1_000)

        let made = try (1...4).map { seconds in
            try store.addDebrief(try Self.recording(seconds: Double(seconds)), language: .english, to: mission,
                                 signer: SoftwareEvidenceSigner(), now: now)
        }

        #expect(try store.debriefs(in: mission) == made)
    }

    @Test func anEmptyOrMissingRecordingIsRefused() throws {
        let store = try store()
        let signer = SoftwareEvidenceSigner()
        let empty = try Self.recording(bytes: Data())
        let missing = Recording(file: FileManager.default.temporaryDirectory.appendingPathComponent("none.m4a"),
                                seconds: 3)

        #expect(throws: MissionStore.EmptyRecording.self) {
            try store.addDebrief(empty, language: .english, to: self.mission, signer: signer)
        }
        #expect(throws: (any Error).self) {
            try store.addDebrief(missing, language: .english, to: self.mission, signer: signer)
        }
        #expect(try store.evidence(in: mission).isEmpty)
    }

    @Test(arguments: [
        "UPDATE debrief SET seconds = 1",
        "UPDATE debrief SET language = 'en'",
        "DELETE FROM debrief",
        "INSERT INTO debrief VALUES ('kandor-roads', 2, 400, 'en', 0)",
        "INSERT INTO debrief VALUES ('kandor-roads', 2, 0, 'en', 0)",
        "INSERT INTO debrief VALUES ('kandor-roads', 2, 30, 'de', 0)"
    ])
    func theDatabaseKeepsDebriefsAsTheyWere(sql: String) throws {
        let store = try store()
        try store.addDebrief(try Self.recording(), language: .french, to: mission, signer: SoftwareEvidenceSigner())
        // Evidence 2 has no debrief yet, so only the length and language rules can refuse the inserts.
        try store.addEvidence(EvidenceChainTests.capture("site"), to: mission, signer: SoftwareEvidenceSigner())

        #expect(throws: DatabaseError.self) { try store.store.rawExecuteForTests(sql) }
    }

    @Test func theAuditNamesTheRecordingNeverWhatWasSaid() throws {
        let store = try store()

        let debrief = try store.addDebrief(try Self.recording(seconds: 42.4), language: .french, to: mission,
                                           signer: SoftwareEvidenceSigner())

        let events = try store.store.auditEvents().filter { $0.action == .debriefRecorded }
        #expect(events.map(\.target) == ["\(debrief.seq) 42 s fr"])
        #expect(try store.store.verifyAudit() == .valid(count: try store.store.auditEvents().count))
    }

    @Test func aDebriefGoesWithItsMission() throws {
        let store = try store()
        try store.addDebrief(try Self.recording(), language: .english, to: mission, signer: SoftwareEvidenceSigner())

        try store.reprovision(mission, at: Date())
        try store.create(mission: mission, title: "Kandor rural roads")

        #expect(try store.debriefs(in: mission).isEmpty)
    }
}
