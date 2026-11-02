import CryptoKit
import Foundation
import Security
import Testing
@testable import MissionCopilot

/// The app's mission keys are wrapped by one Secure Enclave key per mission (ADR 0008 layer C, #70).
/// The chip never exports the private key; its blob in the Keychain only works on this phone's chip.
/// Runs wherever a Secure Enclave exists (Apple silicon Simulators too); the phone run (#74) proves it.
@Suite(.enabled(if: SecureEnclave.isAvailable, "Needs a Secure Enclave"))
struct SecureEnclaveVaultTests {
    private let vault = SecureEnclaveVault(service: "missioncopilot.tests.\(UUID().uuidString)")

    @Test func aMissionKeyRoundTripsThroughTheChip() throws {
        let missionKey = SymmetricKey(size: .bits256)
        defer { try? vault.destroy(mission: "kandor-roads") }

        #expect(try vault.unwrap(vault.wrap(missionKey, for: "kandor-roads"), for: "kandor-roads") == missionKey)
    }

    @Test func destroyingTheChipKeyShredsTheMission() throws {
        let wrapped = try vault.wrap(SymmetricKey(size: .bits256), for: "kandor-roads")

        try vault.destroy(mission: "kandor-roads")

        #expect(throws: MissionKeyNotFound(mission: "kandor-roads")) { try vault.unwrap(wrapped, for: "kandor-roads") }
    }

    @Test func eachMissionHasItsOwnChipKey() throws {
        let otherKey = SymmetricKey(size: .bits256)
        defer { try? vault.destroy(mission: "kandor-bridges") }
        _ = try vault.wrap(SymmetricKey(size: .bits256), for: "kandor-roads")
        let otherWrapped = try vault.wrap(otherKey, for: "kandor-bridges")

        try vault.destroy(mission: "kandor-roads")

        #expect(try vault.unwrap(otherWrapped, for: "kandor-bridges") == otherKey)
    }

    @Test func theChipKeyStaysOnThisPhoneAndIsNeverSynced() throws {
        defer { try? vault.destroy(mission: "kandor-roads") }
        _ = try vault.wrap(SymmetricKey(size: .bits256), for: "kandor-roads")

        let attributes = try vault.keyAttributes(for: "kandor-roads")

        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
    }

    @Test func chipKeysAreUsableOnlyWhileThePhoneIsUnlocked() throws {
        // iOS cannot report this back from a chip key, so the value is pinned; the phone run proves it.
        #expect(ChipKeyAccess.accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        #expect(ChipKeyAccess.flags == .privateKeyUsage)
        _ = try ChipKeyAccess.make()
    }
}
