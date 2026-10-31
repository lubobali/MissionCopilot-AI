import CryptoKit
import Synchronization

/// Software P-256 keys in memory: same HPKE math as the Secure Enclave vault, for Simulator tests only.
public final class SoftwareKeyVault: MissionKeyVault {
    private let keys = Mutex<[String: P256.KeyAgreement.PrivateKey]>([:])

    public init() {}

    public func wrap(_ missionKey: SymmetricKey, for mission: String) throws -> WrappedMissionKey {
        let privateKey = keys.withLock { keys in
            if let existing = keys[mission] { return existing }
            let created = P256.KeyAgreement.PrivateKey()
            keys[mission] = created
            return created
        }
        return try MissionKeyWrap.wrap(missionKey, to: privateKey.publicKey, mission: mission)
    }

    public func unwrap(_ wrapped: WrappedMissionKey, for mission: String) throws -> SymmetricKey {
        guard let privateKey = keys.withLock({ $0[mission] }) else { throw MissionKeyNotFound(mission: mission) }
        return try MissionKeyWrap.unwrap(wrapped, with: privateKey, mission: mission)
    }

    public func destroy(mission: String) throws {
        _ = keys.withLock { $0.removeValue(forKey: mission) }
    }
}
