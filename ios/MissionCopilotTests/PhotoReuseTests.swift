import Foundation
import Testing
@testable import MissionCopilot

/// MC-04 on this phone (#134, step 6.3.4): a mission's photo whose bytes (the signed SHA-256) also appear in
/// another photo, in this mission or another one on the phone, is a flag naming every place it appears.
/// An exact copy only; other phones are checked after sync (Phase 8). A shredded mission cannot be read and
/// is counted as skipped, never as clear.
struct PhotoReuseTests {
    let mission = "kandor-roads"

    private func store(_ missions: [String] = ["kandor-roads", "other-site"]) throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        for id in missions { try store.create(mission: id, title: id) }
        return store
    }

    @discardableResult
    private func add(_ bytes: String, kind: EvidencePayload.Kind = .photo, to mission: String,
                     in store: MissionStore) throws -> Int {
        let capture = Capture(file: Data(bytes.utf8), kind: kind, capturedAt: SiteWalkTests.walkDay,
                              clockSource: .device, location: nil)
        let record = try store.addEvidence(capture, to: mission, signer: SoftwareEvidenceSigner())
        return try JSONDecoder().decode(EvidencePayload.self, from: record.payload).seq
    }

    private func mc04(_ store: MissionStore) throws -> [RedFlagResult] {
        let inputs = RedFlagInputs(photos: try store.photoReuse(for: mission))
        return RedFlagEngineTests.only("MC-04", RedFlagEngine(rules: RedFlagEngineTests.rules)
            .run(inputs, walk: SiteWalkTests.walkDay, timeZone: .gmt))
    }

    @Test func aPhotoAlsoInAnotherMissionIsAFlagNamingBoth() throws {
        let store = try store()
        let here = try add("road at km 18", to: mission, in: store)
        let there = try add("road at km 18", to: "other-site", in: store)

        let results = try mc04(store)

        #expect(results.map(\.outcome) == [.flag])
        #expect(results.first?.computed == 2)
        #expect(results.first?.inputs == [.evidence(PhotoRef(mission: "kandor-roads", seq: here)),
                                          .evidence(PhotoRef(mission: "other-site", seq: there))])
    }

    @Test func theSamePhotoTwiceInOneMissionIsOneFlag() throws {
        let store = try store()
        try add("bridge", to: mission, in: store)
        try add("bridge", to: mission, in: store)

        let results = try mc04(store)

        #expect(results.map(\.outcome) == [.flag])
        #expect(results.first?.computed == 2)
    }

    @Test func differentPhotosAreClearAndCiteEachPhotoChecked() throws {
        let store = try store()
        let first = try add("road", to: mission, in: store)
        let second = try add("drain", to: mission, in: store)
        try add("elsewhere", to: "other-site", in: store)

        let results = try mc04(store)

        #expect(results.map(\.outcome) == [.clear])
        #expect(results.first?.computed == 1)
        #expect(results.first?.inputs == [.evidence(PhotoRef(mission: mission, seq: first)),
                                          .evidence(PhotoRef(mission: mission, seq: second))])
    }

    @Test func aScanWithTheSameBytesIsNotAPhoto() throws {
        let store = try store()
        try add("page", to: mission, in: store)
        try add("page", kind: .scan, to: "other-site", in: store)

        #expect(try mc04(store).map(\.outcome) == [.clear])
    }

    @Test func withNoPhotosYetItIsNotChecked() throws {
        let store = try store()
        try add("page", kind: .scan, to: mission, in: store)

        #expect(try mc04(store).map(\.outcome) == [.notChecked(.needsPhotos)])
    }

    @Test func aShreddedMissionIsSkippedAndCountedNeverClear() throws {
        let store = try store(["kandor-roads", "other-site", "old-mission"])
        try add("road", to: mission, in: store)
        try add("road", to: "old-mission", in: store)
        try store.shred(mission: "old-mission")

        let check = try store.photoReuse(for: mission)
        let results = try mc04(store)

        #expect(check.skipped == ["old-mission"])
        #expect(results.map(\.outcome) == [.clear])
        #expect(results.first?.skippedMissions == 1)
    }
}
