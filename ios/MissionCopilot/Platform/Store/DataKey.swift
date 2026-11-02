import Foundation
import LocalAuthentication
import Security

/// 32 random bytes that unlock one user's encrypted database (ADR 0008 layer B).
struct DataKey: Sendable, Equatable {
    let bytes: Data

    static func random() throws -> DataKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainDataKeyStore.Failure(status: status) }
        return DataKey(bytes: Data(bytes))
    }

    /// SQLCipher's raw key form x'<64 hex>': the key is used as is, no slow password stretching.
    var rawKeyLiteral: String {
        "x'" + bytes.map { String(format: "%02x", $0) }.joined() + "'"
    }
}

/// Where each user's database key is kept. The app uses the Keychain; tests can use any store.
protocol DataKeyStore: Sendable {
    /// - Parameter context: the Face ID or passcode authentication that just succeeded, so the key is
    ///   released without a second prompt (nil in tests and before the app lock).
    func loadOrCreate(for user: String, context: LAContext?) throws -> DataKey
    func delete(for user: String) throws
}

extension DataKeyStore {
    func loadOrCreate(for user: String) throws -> DataKey {
        try loadOrCreate(for: user, context: nil)
    }
}
