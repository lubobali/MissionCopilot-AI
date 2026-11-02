import Foundation

/// Puts one user's store together (ADR 0008): their protected folder (layer A), their key from the
/// Keychain (layer B), the encrypted database inside, always pausing on lock. The app opens it only
/// after the person unlocks the app (app lock, #73).
enum UserStore {
    static let fileName = "store.sqlite"

    /// Where the app keeps stores and keys; tests pass their own folder and key store instead.
    struct Live: Sendable {
        let base: URL
        let keys: KeychainDataKeyStore
    }

    static let live = Live(
        base: URL.applicationSupportDirectory.appendingPathComponent("Stores", isDirectory: true),
        keys: .app
    )

    static func open(user: String, in base: URL, keys: some DataKeyStore) throws -> EncryptedStore {
        let folder = try ProtectedFolder.create(for: user, in: base)
        let key = try keys.loadOrCreate(for: user)
        return try EncryptedStore.open(at: folder.appendingPathComponent(fileName), key: key, suspendable: true)
    }
}
