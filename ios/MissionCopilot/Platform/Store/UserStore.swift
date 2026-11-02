import Foundation
import LocalAuthentication

/// Puts one user's store together (ADR 0008): their protected folder (layer A), their key from the
/// Keychain (layer B), the encrypted database inside, always pausing on lock. The app opens it only
/// after the person unlocks the app (app lock, #73).
enum UserStore {
    static let fileName = "store.sqlite"

    /// Where the app keeps stores and keys; tests pass their own folder and key store instead.
    struct Live: Sendable {
        let base: URL
        let keys: KeychainDataKeyStore
        let vault: SecureEnclaveVault
    }

    static let live = Live(
        base: URL.applicationSupportDirectory.appendingPathComponent("Stores", isDirectory: true),
        keys: .app,
        vault: .app
    )

    /// A user's missions, after the lease check (ADR 0012).
    struct Opened: Sendable {
        let missions: MissionStore
        /// Missions shredded by this check, to show the officer and report on the next sync.
        let shredded: [ShredRecord]
    }

    /// Opens a user's missions and enforces their leases first, so nothing past its lease is ever read.
    /// The app calls this at launch and at every unlock (app lock, #73).
    static func openMissions(user: String, in base: URL, keys: some DataKeyStore, vault: any MissionKeyVault,
                             context: LAContext? = nil, now: Date = Date()) throws -> Opened {
        let missions = MissionStore(store: try open(user: user, in: base, keys: keys, context: context), vault: vault)
        return Opened(missions: missions, shredded: try missions.enforce(now: now))
    }

    /// - Parameter context: the Face ID or passcode authentication that just succeeded (one prompt).
    static func open(user: String, in base: URL, keys: some DataKeyStore,
                     context: LAContext? = nil) throws -> EncryptedStore {
        let folder = try ProtectedFolder.create(for: user, in: base)
        let key = try keys.loadOrCreate(for: user, context: context)
        return try EncryptedStore.open(at: folder.appendingPathComponent(fileName), key: key, suspendable: true)
    }
}
