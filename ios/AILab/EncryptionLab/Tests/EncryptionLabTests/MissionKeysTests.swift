import CryptoKit
import Foundation
import Testing
@testable import EncryptionLab

struct MissionKeysTests {
    private let vault = SoftwareKeyVault()

    @Test func wrappedMissionKeyUnwrapsToTheSameKey() throws {
        let missionKey = SymmetricKey(size: .bits256)
        let wrapped = try vault.wrap(missionKey, for: "kandor-roads")

        let unwrapped = try vault.unwrap(wrapped, for: "kandor-roads")

        #expect(unwrapped == missionKey)
    }

    @Test func destroyedMissionCannotBeUnwrapped() throws {
        let wrapped = try vault.wrap(SymmetricKey(size: .bits256), for: "kandor-roads")

        try vault.destroy(mission: "kandor-roads")

        // Crypto-shred: the wrapped key may still exist somewhere, but nothing can open it any more.
        #expect(throws: (any Error).self) {
            try vault.unwrap(wrapped, for: "kandor-roads")
        }
    }

    @Test func destroyingOneMissionLeavesTheOthersReadable() throws {
        let otherKey = SymmetricKey(size: .bits256)
        _ = try vault.wrap(SymmetricKey(size: .bits256), for: "kandor-roads")
        let otherWrapped = try vault.wrap(otherKey, for: "kandor-bridges")

        try vault.destroy(mission: "kandor-roads")

        #expect(try vault.unwrap(otherWrapped, for: "kandor-bridges") == otherKey)
    }

    @Test func wrappedKeyCannotBeOpenedAsAnotherMission() throws {
        let wrapped = try vault.wrap(SymmetricKey(size: .bits256), for: "kandor-roads")
        _ = try vault.wrap(SymmetricKey(size: .bits256), for: "kandor-bridges")

        #expect(throws: (any Error).self) {
            try vault.unwrap(wrapped, for: "kandor-bridges")
        }
    }

    @Test func wrappedKeyDoesNotContainTheRawKey() throws {
        let missionKey = SymmetricKey(size: .bits256)
        let raw = missionKey.withUnsafeBytes { Data($0) }

        let wrapped = try vault.wrap(missionKey, for: "kandor-roads")

        #expect(wrapped.ciphertext.range(of: raw) == nil)
        #expect(wrapped.encapsulatedKey.range(of: raw) == nil)
    }

    @Test func missionDataOpensWithItsKeyAndRejectsTampering() throws {
        let missionKey = SymmetricKey(size: .bits256)
        let sealed = try MissionData.seal(Data("Km 42 culvert washed out".utf8), with: missionKey)

        #expect(try MissionData.open(sealed, with: missionKey) == Data("Km 42 culvert washed out".utf8))

        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: (any Error).self) {
            try MissionData.open(tampered, with: missionKey)
        }
    }
}

struct MissionKeyWrapTests {
    @Test func sameWrappingKeyButOtherMissionFailsToOpen() throws {
        // Targets the mission binding itself: even with the right private key, the wrong mission is refused.
        let privateKey = P256.KeyAgreement.PrivateKey()
        let wrapped = try MissionKeyWrap.wrap(SymmetricKey(size: .bits256), to: privateKey.publicKey,
                                              mission: "kandor-roads")

        #expect(throws: (any Error).self) {
            try MissionKeyWrap.unwrap(wrapped, with: privateKey, mission: "kandor-bridges")
        }
    }
}
