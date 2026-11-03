import CryptoKit
import Foundation
import Testing
import UIKit
@testable import MissionCopilot

/// Freshness and rollback (#91, threat T51): a pack is used only for the mission and organization the
/// phone asked for, and its version must be above the last one this phone accepted for that mission, so
/// an older pack cannot be played back. Fetching the same pack again (same version, same bytes) is fine;
/// the same version with other content is refused: a real server never does that. The last accepted
/// version lives in the encrypted mission store.
struct PackAcceptanceTests {
    static let mission = "6f1d2c3a-0000-4000-8000-000000000001"
    static let org = "kandor-works"

    private func store() throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        return MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()), vault: SoftwareKeyVault())
    }

    private func manifest(version: Int, mission: String = mission, org: String = org) -> PackManifest {
        PackManifest(packId: UUID().uuidString.lowercased(), orgId: org, missionId: mission, version: version,
                     createdAt: Date(), expiresAt: Date().addingTimeInterval(86_400), minAppVersion: "0.5",
                     keyId: "0123456789abcdef", files: [])
    }

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    private func accept(_ pack: PackManifest, _ data: Data, in store: MissionStore,
                        mission: String = mission, org: String = org) throws(PackRefusal) {
        try PackAcceptance.check(pack, manifestBytes: data, asked: (org: org, mission: mission), in: store)
    }

    @Test func theFirstPackOfAMissionIsAccepted() throws {
        let store = try store()

        try accept(manifest(version: 1), bytes("v1"), in: store)
    }

    @Test func aPackForAnotherMissionOrOrganizationIsRefused() throws {
        let store = try store()

        #expect(throws: PackRefusal.wrongMission) {
            try accept(manifest(version: 1, mission: "6f1d2c3a-0000-4000-8000-000000000002"), bytes("x"), in: store)
        }
        #expect(throws: PackRefusal.wrongMission) {
            try accept(manifest(version: 1, org: "someone-else"), bytes("x"), in: store)
        }
    }

    @Test func aNewerVersionIsAcceptedAndRemembered() throws {
        let store = try store()
        try PackAcceptance.record(manifest(version: 3), manifestBytes: bytes("v3"), in: store)

        try accept(manifest(version: 4), bytes("v4"), in: store)
        #expect(try store.lastAcceptedPack(for: Self.mission)?.version == 3)  // check alone remembers nothing
    }

    @Test func anOlderVersionIsRefusedSoItCannotBePlayedBack() throws {
        let store = try store()
        try PackAcceptance.record(manifest(version: 3), manifestBytes: bytes("v3"), in: store)

        #expect(throws: PackRefusal.older) { try accept(manifest(version: 2), bytes("v2"), in: store) }
    }

    @Test func theSamePackFetchedAgainIsFine() throws {
        let store = try store()
        try PackAcceptance.record(manifest(version: 3), manifestBytes: bytes("v3"), in: store)

        try accept(manifest(version: 3), bytes("v3"), in: store)
    }

    @Test func theSameVersionWithOtherContentIsRefused() throws {
        let store = try store()
        try PackAcceptance.record(manifest(version: 3), manifestBytes: bytes("v3"), in: store)

        #expect(throws: PackRefusal.replaced) { try accept(manifest(version: 3), bytes("v3, changed"), in: store) }
    }

    @Test func recordingKeepsTheVersionAndTheManifestsHash() throws {
        let store = try store()

        try PackAcceptance.record(manifest(version: 5), manifestBytes: bytes("v5"), in: store)

        let last = try #require(try store.lastAcceptedPack(for: Self.mission))
        #expect(last.version == 5)
        #expect(last.manifestSHA256 == SHA256.hash(data: bytes("v5")).map { String(format: "%02x", $0) }.joined())
    }

    @Test func recordingNeverMovesTheVersionBack() throws {
        let store = try store()
        try PackAcceptance.record(manifest(version: 5), manifestBytes: bytes("v5"), in: store)

        #expect(throws: PackRefusal.older) {
            try PackAcceptance.record(manifest(version: 4), manifestBytes: bytes("v4"), in: store)
        }
        #expect(try store.lastAcceptedPack(for: Self.mission)?.version == 5)
    }

    @Test func eachMissionHasItsOwnVersion() throws {
        let store = try store()
        let other = "6f1d2c3a-0000-4000-8000-000000000002"
        try PackAcceptance.record(manifest(version: 9), manifestBytes: bytes("roads"), in: store)

        try accept(manifest(version: 1, mission: other), bytes("bridges"), in: store, mission: other)
    }
}

/// A paused store (the phone just locked) must never read as "nothing accepted yet".
@Suite(.serialized, .takesTurnsWithThePause)
struct PackAcceptanceWhileLockedTests {
    @Test func whenTheStoreCannotBeReadTheCheckRefusesInsteadOfAssuming() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random(), suspendable: true),
                                 vault: SoftwareKeyVault())
        let pack = PackManifest(packId: "p", orgId: "kandor-works", missionId: PackAcceptanceTests.mission, version: 1,
                                createdAt: Date(), expiresAt: Date(), minAppVersion: "0.5", keyId: "k", files: [])
        let center = NotificationCenter()
        let suspension = StoreSuspension(observing: center)
        defer { center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil) }
        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)

        #expect(throws: PackRefusal.storeUnavailable) {
            let asked = (org: "kandor-works", mission: PackAcceptanceTests.mission)
            try PackAcceptance.check(pack, manifestBytes: Data(), asked: asked, in: store)
        }
        _ = suspension
    }
}
