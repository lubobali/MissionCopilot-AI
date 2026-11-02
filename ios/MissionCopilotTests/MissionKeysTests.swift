import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// One key per mission, stored only wrapped (ADR 0008 layer C, #70). Destroying the wrapping key is the
/// crypto-shred: any copy of the wrapped key, wherever it survived, can no longer be opened.
struct MissionKeysTests {
    private let vault = SoftwareKeyVault()

    @Test func aWrappedMissionKeyUnwrapsToTheSameKey() throws {
        let missionKey = SymmetricKey(size: .bits256)

        #expect(try vault.unwrap(vault.wrap(missionKey, for: "kandor-roads"), for: "kandor-roads") == missionKey)
    }

    @Test func aDestroyedMissionCannotBeUnwrapped() throws {
        let wrapped = try vault.wrap(SymmetricKey(size: .bits256), for: "kandor-roads")

        try vault.destroy(mission: "kandor-roads")

        #expect(throws: MissionKeyNotFound(mission: "kandor-roads")) { try vault.unwrap(wrapped, for: "kandor-roads") }
    }

    @Test func destroyingOneMissionLeavesTheOthersReadable() throws {
        let otherKey = SymmetricKey(size: .bits256)
        _ = try vault.wrap(SymmetricKey(size: .bits256), for: "kandor-roads")
        let otherWrapped = try vault.wrap(otherKey, for: "kandor-bridges")

        try vault.destroy(mission: "kandor-roads")

        #expect(try vault.unwrap(otherWrapped, for: "kandor-bridges") == otherKey)
    }

    @Test func aWrappedKeyCannotBeOpenedAsAnotherMissionEvenWithTheRightPrivateKey() throws {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let missionKey = SymmetricKey(size: .bits256)
        let wrapped = try MissionKeyWrap.wrap(missionKey, to: privateKey.publicKey, mission: "kandor-roads")

        #expect(throws: (any Error).self) {
            try MissionKeyWrap.unwrap(wrapped, with: privateKey, mission: "kandor-bridges")
        }
        #expect(try MissionKeyWrap.unwrap(wrapped, with: privateKey, mission: "kandor-roads") == missionKey)
    }

    @Test func theWrappedKeyNeverContainsTheRawKey() throws {
        let missionKey = SymmetricKey(size: .bits256)
        let raw = missionKey.withUnsafeBytes { Data($0) }

        let wrapped = try vault.wrap(missionKey, for: "kandor-roads")

        #expect(wrapped.ciphertext.range(of: raw) == nil && wrapped.encapsulatedKey.range(of: raw) == nil)
    }

    @Test func missionDataOpensWithItsKeyAndRefusesTampering() throws {
        let missionKey = SymmetricKey(size: .bits256)
        let sealed = try MissionData.seal(Data("Km 42 culvert washed out".utf8), with: missionKey)
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01

        #expect(try MissionData.open(sealed, with: missionKey) == Data("Km 42 culvert washed out".utf8))
        #expect(throws: (any Error).self) { try MissionData.open(tampered, with: missionKey) }
        #expect(throws: (any Error).self) { try MissionData.open(sealed, with: SymmetricKey(size: .bits256)) }
    }
}
