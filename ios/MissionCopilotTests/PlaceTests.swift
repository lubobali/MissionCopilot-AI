import Foundation
import Testing
@testable import MissionCopilot

/// The sample point's place (#129, step 6.2.4): asked for only when the officer taps, written as an
/// XLSForm geopoint answer, and every way it can fail said in words with what to do.
@MainActor
struct PlaceTests {
    actor FakePlaces: PlaceFinder {
        let reading: PlaceReading
        private(set) var asked = 0
        init(_ reading: PlaceReading) { self.reading = reading }
        func onePlace() async -> PlaceReading {
            asked += 1
            return reading
        }
    }

    static let kmEighteen = Place(latitude: 1.0600004, longitude: 1.05, altitude: 312.46, accuracy: 4.2)

    @Test func aPlaceIsWrittenAsAnXLSFormGeopoint() {
        // "latitude longitude altitude accuracy", metres; six decimals is about 11 cm.
        #expect(Self.kmEighteen.geopoint == "1.060000 1.050000 312.5 4.2")
    }

    @Test func aGeopointAnswerReadsBackWithItsAccuracy() {
        #expect(Place(geopoint: "1.060000 1.050000 312.5 4.2") == Place(latitude: 1.06, longitude: 1.05,
                                                                          altitude: 312.5, accuracy: 4.2))
        #expect(Place(geopoint: "not a place") == nil)
        #expect(Place(geopoint: "1.06 1.05") == nil)
    }

    @Test func everyFailureSaysWhatToDo() {
        #expect(PlaceReading.denied.problem(app: "MC Staging")
                == "Location is off for MC Staging. Turn it on in Settings, then try again.")
        #expect(PlaceReading.offForPhone.problem(app: "MC Staging")
                == "Location Services are off on this iPhone. Turn them on in Settings, Privacy & Security.")
        #expect(PlaceReading.restricted.problem(app: "MC Staging")
                == "Location is blocked on this iPhone by its settings or your organization.")
        #expect(PlaceReading.noFix.problem(app: "MC Staging")
                == "No position yet. Move under open sky, wait a moment, and try again.")
        #expect(PlaceReading.place(Self.kmEighteen).problem(app: "MC Staging") == nil)
    }

    private func walk(_ places: FakePlaces) throws -> SiteWalkModel {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: "kandor-roads", title: "Kandor rural roads")
        let (form, actions) = try SiteWalkTests.kandor()
        return try SiteWalkModel(form: form, actions: actions, mission: "kandor-roads", store: store,
                                 now: { SiteWalkTests.walkDay }, timeZone: .gmt, preferred: ["en-US"],
                                 places: places)
    }

    @Test func recordingThePlaceSavesItAsTheAnswer() async throws {
        let places = FakePlaces(.place(Self.kmEighteen))
        let walk = try walk(places)

        await walk.recordPlace(for: "sample_point")

        #expect(walk.walk.answers["sample_point"] == "1.060000 1.050000 312.5 4.2")
        #expect(walk.problem == nil)
    }

    @Test func aRefusedPlaceSavesNothingAndSaysWhy() async throws {
        let walk = try walk(FakePlaces(.denied))

        await walk.recordPlace(for: "sample_point")

        #expect(walk.walk.answers["sample_point"] == nil)
        #expect(walk.problem?.hasPrefix("Location is off for ") == true)
    }

    @Test func openingTheWalkNeverAsksForThePlace() async throws {
        // Asked only when the officer taps (MASVS-PRIVACY-1): opening the walk touches no location.
        let places = FakePlaces(.place(Self.kmEighteen))
        _ = try walk(places)

        #expect(await places.asked == 0)
    }
}
