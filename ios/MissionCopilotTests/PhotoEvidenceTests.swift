import Foundation
import ImageIO
import Testing
import UIKit
@testable import MissionCopilot

/// A site photo becomes signed evidence (#129, step 6.2.8): prepared (no metadata in the file), its place
/// read when the camera opened, signed into the mission's chain with the phone's key, sealed with the
/// mission key. With no place it is still kept, and says so; after the finish no photo is added.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PhotoEvidenceTests {
    let mission = "kandor-roads"

    private func walk(_ places: PlaceTests.FakePlaces) throws -> (SiteWalkModel, MissionStore) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        let (form, actions) = try SiteWalkTests.kandor()
        let walk = try SiteWalkModel(form: form, actions: actions, mission: mission, store: store,
                                     now: { SiteWalkTests.walkDay }, timeZone: .gmt, preferred: ["en-US"],
                                     places: places, signer: SoftwareEvidenceSigner())
        return (walk, store)
    }

    private func photo() throws -> UIImage {
        try #require(UIImage(data: try SitePhotoTests.cameraJPEG(width: 4032, height: 3024)))
    }

    private func payload(_ store: MissionStore, _ seq: Int) throws -> EvidencePayload {
        let record = try #require(try store.evidence(in: mission).first { record in
            (try? JSONDecoder().decode(EvidencePayload.self, from: record.payload))?.seq == seq
        })
        return try JSONDecoder().decode(EvidencePayload.self, from: record.payload)
    }

    @Test func aPhotoIsSignedEvidenceWithThePlaceReadWhenTheCameraOpened() async throws {
        let places = PlaceTests.FakePlaces(.place(PlaceTests.kmEighteen))
        let (walk, store) = try walk(places)

        walk.cameraOpening()
        walk.cameraOpening()  // opened twice (a retake): still one reading
        let seq = try #require(await walk.photoTaken(try photo()))

        let signed = try payload(store, seq)
        #expect(signed.kind == .photo)
        #expect(signed.location == EvidencePayload.Location(latitude: 1.0600004, longitude: 1.05))
        #expect(signed.clockSource == .device)
        #expect(await places.asked == 1, "one reading, started when the camera opened")
        #expect(walk.problem == nil)
    }

    @Test func theStoredFileIsThePreparedPhotoWithNoPlaceInsideIt() async throws {
        let (walk, store) = try walk(PlaceTests.FakePlaces(.place(PlaceTests.kmEighteen)))
        walk.cameraOpening()
        let seq = try #require(await walk.photoTaken(try photo()))

        let file = try store.evidenceFile(in: mission, seq: seq)

        let properties = try SitePhotoTests.properties(file)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyPixelWidth] as? Int) == 2048)
    }

    @Test func withNoPlaceThePhotoIsStillKeptAndSaysSo() async throws {
        let (walk, store) = try walk(PlaceTests.FakePlaces(.denied))
        walk.cameraOpening()

        let seq = try #require(await walk.photoTaken(try photo()))

        #expect(try payload(store, seq).location == nil)
        #expect(walk.problem?.hasPrefix("The photo is saved without its place.") == true)
    }

    @Test func aPhotoTakenWithoutOpeningFirstStillReadsThePlace() async throws {
        let places = PlaceTests.FakePlaces(.place(PlaceTests.kmEighteen))
        let (walk, store) = try walk(places)

        let seq = try #require(await walk.photoTaken(try photo()))

        #expect(try payload(store, seq).location != nil)
        #expect(await places.asked == 1)
    }

    @Test func afterTheFinishNoPhotoIsAdded() async throws {
        let (walk, store) = try walk(PlaceTests.FakePlaces(.place(PlaceTests.kmEighteen)))
        let (answers, checks) = try SiteWalkTests.complete()
        for (question, value) in answers { walk.answer(value, to: question) }
        for (key, check) in checks { walk.check(check.seen, note: nil, action: key) }
        #expect(walk.finish())

        let seq = await walk.photoTaken(try photo())

        #expect(seq == nil)
        #expect(try store.evidence(in: mission).isEmpty)
        #expect(walk.problem == SiteWalkModel.finishedProblem)
    }
}

/// Photos in the walk (#129, step 6.2.9): on the checklist's photo question and on an agreed action.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WalkPhotoTests {
    let mission = "kandor-roads"

    private func walk() throws -> (SiteWalkModel, MissionStore) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        let (form, actions) = try SiteWalkTests.kandor()
        let walk = try SiteWalkModel(form: form, actions: actions, mission: mission, store: store,
                                     now: { SiteWalkTests.walkDay }, timeZone: .gmt, preferred: ["en-US"],
                                     places: PlaceTests.FakePlaces(.place(PlaceTests.kmEighteen)),
                                     signer: SoftwareEvidenceSigner())
        return (walk, store)
    }

    private func photo() throws -> UIImage {
        try #require(UIImage(data: try SitePhotoTests.cameraJPEG(width: 1200, height: 900)))
    }

    @Test func thePhotoQuestionPointsAtItsEvidenceAndARetakePointsAtTheNewest() async throws {
        let (walk, store) = try walk()

        let first = try #require(await walk.photoTaken(try photo(), for: .question("sample_photo")))
        let second = try #require(await walk.photoTaken(try photo(), for: .question("sample_photo")))

        #expect(walk.walk.answers["sample_photo"] == "evidence:\(second)")
        #expect(first != second)
        #expect(try store.evidence(in: mission).count == 2, "the first photo stays: evidence is append-only")
    }

    @Test func anAgreedActionsPhotoKeepsWhatWasSeenAndTheNote() async throws {
        let (walk, _) = try walk()
        let key = walk.walk.actions.actions[0].key
        walk.check(.notStarted, note: "No works at the bridge", action: key)

        let seq = try #require(await walk.photoTaken(try photo(), for: .action(key)))

        #expect(walk.walk.checks[key] == ActionCheck(seen: .notStarted, note: "No works at the bridge", photo: seq))
    }

    @Test func changingWhatWasSeenKeepsThePhoto() async throws {
        let (walk, _) = try walk()
        let key = walk.walk.actions.actions[0].key
        walk.check(.notStarted, note: nil, action: key)
        let seq = try #require(await walk.photoTaken(try photo(), for: .action(key)))

        walk.check(.inProgress, note: "Piers started", action: key)

        #expect(walk.walk.checks[key]?.photo == seq)
    }

    @Test func anActionsPhotoNeedsWhatWasSeenFirst() async throws {
        let (walk, store) = try walk()
        let key = walk.walk.actions.actions[0].key

        let seq = await walk.photoTaken(try photo(), for: .action(key))

        #expect(seq == nil)
        #expect(try store.evidence(in: mission).isEmpty, "no photo is taken for nothing")
        #expect(walk.problem == SiteWalkWords().text(.pickFirst))
    }

    @Test func aPhotoComesBackAsAThumbnailFromItsSealedFile() async throws {
        let (walk, _) = try walk()
        let seq = try #require(await walk.photoTaken(try photo(), for: .question("sample_photo")))

        let thumbnail = try #require(walk.thumbnail(seq))

        #expect(max(thumbnail.size.width, thumbnail.size.height) * thumbnail.scale <= 600)
        #expect(walk.thumbnail(99) == nil)
    }

    @Test func anEvidenceAnswerNamesItsSeq() {
        #expect(SiteWalkModel.photoSeq(inAnswer: "evidence:12") == 12)
        #expect(SiteWalkModel.photoSeq(inAnswer: "evidence:x") == nil)
        #expect(SiteWalkModel.photoSeq(inAnswer: "") == nil)
    }
}
