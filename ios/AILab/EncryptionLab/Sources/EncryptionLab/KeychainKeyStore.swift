import Foundation
import Security

/// Keeps each user's database key in the Keychain: this device only, readable only while unlocked.
public struct KeychainKeyStore: Sendable {
    private let items: KeychainItems

    public init(service: String = "com.lubobali.missioncopilot.dbkey") {
        items = KeychainItems(service: service)
    }

    public func loadOrCreate(for user: String) throws -> DatabaseKey {
        if let existing = try items.load(user) {
            return DatabaseKey(bytes: existing)
        }
        let key = DatabaseKey.random()
        do {
            try items.add(key.bytes, account: user)
        } catch KeychainError.duplicate {
            // Another caller created it first: use theirs so both open the same database.
            if let raced = try items.load(user) { return DatabaseKey(bytes: raced) }
            throw KeychainError(status: errSecDuplicateItem)
        }
        return key
    }

    /// Deleting the key makes that user's database unreadable for good.
    public func delete(for user: String) throws {
        try items.delete(user)
    }

    func attributes(for user: String) throws -> [String: Any] {
        try items.attributes(user)
    }
}

extension KeychainError {
    static let duplicate = KeychainError(status: errSecDuplicateItem)

    static func ~= (pattern: KeychainError, error: any Error) -> Bool {
        (error as? KeychainError) == pattern
    }
}
