import Foundation
import Testing
@testable import MissionCopilot

/// The server's list as the phone reads it (listMyMissions, #92): Postgres times carry microseconds, the
/// fixture's carry none, and a mission with no pack yet says null.
struct MissionListTests {
    @Test func timesWithMicrosecondsAndWithoutBothRead() throws {
        let body = #"""
            {"orgId":"kandor-works","missions":[
             {"id":"6f1d2c3a-0000-4000-8000-000000000001","title":"Roads",
              "pack":{"version":2,"createdAt":"2026-11-03T17:25:10.123456Z","expiresAt":"2026-12-03T17:25:10Z"}},
             {"id":"6f1d2c3a-0000-4000-8000-000000000002","title":"Bridges","pack":null}]}
            """#

        let list = try MissionList.decode(Data(body.utf8))

        let roads = try #require(list.missions.first?.pack)
        #expect(abs(roads.createdAt.timeIntervalSince1970 - 1_793_726_710.123) < 0.001)
        #expect(roads.expiresAt.timeIntervalSince1970 == 1_796_318_710)
        #expect(list.missions.last?.pack == nil && list.orgId == "kandor-works")
    }

    @Test func aTimeThatIsNotISO8601IsRefused() {
        let body = #"""
            {"orgId":"o","missions":[{"id":"x","title":"t",
             "pack":{"version":1,"createdAt":"yesterday","expiresAt":"2026-12-03T17:25:10Z"}}]}
            """#

        #expect(throws: (any Error).self) { try MissionList.decode(Data(body.utf8)) }
    }

    @Test func theListKeptInTheStoreReadsBackTheSame() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        let list = try MissionList.decode(FakePackServer.missions(version: 1))

        try store.cacheMissionList(list)

        #expect(try store.cachedMissionList() == list)
    }
}
