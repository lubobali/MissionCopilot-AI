import CryptoKit
import Foundation
import Security
import Testing
@testable import EncryptionLab

// The Simulator on an Apple Silicon Mac uses the Mac's Secure Enclave, so these run there; machines without
// one (some CI runners) skip them. The AI Lab app proves them on the iPhone.
@Suite(.enabled(if: SecureEnclave.isAvailable, "No Secure Enclave here, proven on device"))
struct SecureEnclaveKeyVaultTests {
    private let vault = SecureEnclaveKeyVault(service: "test.\(UUID().uuidString)")

    @Test func wrappedMissionKeyUnwrapsWithTheChip() throws {
        let missionKey = SymmetricKey(size: .bits256)
        let wrapped = try vault.wrap(missionKey, for: "kandor-roads")

        #expect(try vault.unwrap(wrapped, for: "kandor-roads") == missionKey)
        try vault.destroy(mission: "kandor-roads")
    }

    @Test func destroyedMissionCannotBeUnwrapped() throws {
        let wrapped = try vault.wrap(SymmetricKey(size: .bits256), for: "kandor-roads")

        try vault.destroy(mission: "kandor-roads")

        #expect(throws: MissionKeyNotFound(mission: "kandor-roads")) {
            try vault.unwrap(wrapped, for: "kandor-roads")
        }
    }

    @Test func chipKeyBlobStaysOnThisDeviceAndNeedsUnlock() throws {
        _ = try vault.wrap(SymmetricKey(size: .bits256), for: "kandor-roads")

        let attributes = try vault.keyAttributes(for: "kandor-roads")

        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try vault.destroy(mission: "kandor-roads")
    }
}

struct SecureEnclaveAccessTests {
    @Test func chipKeyRequiresUnlockAndThisDeviceOnly() {
        // Guard against weakening it by accident; the phone-lock proof checks the real behaviour.
        #expect(SecureEnclaveKeyVault.chipKeyAccessibility as String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
}

struct SecureEnclaveAvailabilityTests {
    @Test func reportsWhetherTheChipIsHere() {
        // Recorded in the test log so CI and the device run show which path ran.
        print("SecureEnclave.isAvailable =", SecureEnclave.isAvailable)
    }
}
