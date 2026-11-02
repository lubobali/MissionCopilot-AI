import Foundation
import Security

/// Each user's database key in the Keychain: never synced, this phone only, and in the app released
/// only after Face ID or the passcode while the phone has a passcode (DataKeyAccess, ADR 0012).
/// Tests pass another access control so the Simulator runs the same code without a prompt.
struct KeychainDataKeyStore: DataKeyStore {
    typealias Failure = KeychainFailure

    static let app = KeychainDataKeyStore(service: "com.lubobali.missioncopilot.datakey")

    let service: String
    let usesAppRule: Bool
    private let items: KeychainItems
    private let access: @Sendable () throws -> SecAccessControl

    init(service: String, access: (@Sendable () throws -> SecAccessControl)? = nil) {
        self.service = service
        self.usesAppRule = access == nil
        self.items = KeychainItems(service: service)
        self.access = access ?? DataKeyAccess.make
    }

    func loadOrCreate(for user: String) throws -> DataKey {
        if let existing = try items.load(user) { return DataKey(bytes: existing) }
        let key = try DataKey.random()
        if try items.add(key.bytes, account: user, access: access()) { return key }
        // Another caller created it first: both open the same database.
        guard let raced = try items.load(user) else { throw Failure(status: errSecDuplicateItem) }
        return DataKey(bytes: raced)
    }

    /// Deleting the key makes that user's database unreadable for good.
    func delete(for user: String) throws {
        try items.delete(user)
    }

    func attributes(for user: String) throws -> [String: Any] {
        try items.attributes(user)
    }
}
