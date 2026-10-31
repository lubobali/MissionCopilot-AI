import Foundation
import Security

/// 32 random bytes that unlock one user's SQLCipher database (ADR 0008, layer 2).
public struct DatabaseKey: Sendable, Equatable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public static func random() -> DatabaseKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "System random generator failed: \(status)")
        return DatabaseKey(bytes: Data(bytes))
    }

    /// SQLCipher raw key form x'<64 hex>': used as the key directly, no slow password stretching.
    var rawKeyLiteral: String {
        "x'" + bytes.map { String(format: "%02x", $0) }.joined() + "'"
    }
}
