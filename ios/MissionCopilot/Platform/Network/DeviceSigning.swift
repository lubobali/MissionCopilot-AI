import CryptoKit
import Foundation

/// The exact bytes the phone signs with its chip key (docs/security.md, #90). The server builds the same
/// bytes (devices.enrollment_message, device_auth.request_message) and a shared fixture proves they match.
/// Each kind of message starts with its own label, so a signature can never be reused for another kind.
enum DeviceSigning {
    enum Failure: Error, Equatable { case badPath, badSequence, badMethod }

    static let enrollDomain = Data("missioncopilot-enroll-v1\n".utf8)
    static let requestDomain = Data("missioncopilot-request-v1\n".utf8)
    static let methods: Set<String> = ["GET", "POST"]
    /// The server checks the path as it decodes it. Plain characters only (no %-escapes, spaces or line
    /// breaks), so the phone and the server can never read the same path differently.
    private static let pathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._~?=&")

    /// Enrolling: the label, the one-time code, a newline, then the public key (DER).
    static func enrollmentMessage(code: String, publicKeyDER: Data) -> Data {
        enrollDomain + Data(code.utf8) + Data("\n".utf8) + publicKeyDER
    }

    /// Every request: the label, then method, path with query, device id, sequence number, Unix time and
    /// the body's SHA-256 (lowercase hex), one per line.
    static func requestMessage(_ request: SignedRequest) throws -> Data {
        guard methods.contains(request.method) else { throw Failure.badMethod }
        let path = request.path
        guard path.hasPrefix("/"), path.unicodeScalars.allSatisfy(pathCharacters.contains) else {
            throw Failure.badPath
        }
        guard request.seq >= 1 else { throw Failure.badSequence }
        let bodyHash = SHA256.hash(data: request.body).map { String(format: "%02x", $0) }.joined()
        let fields = [request.method, path, request.deviceId, String(request.seq), String(request.time), bodyHash]
        return requestDomain + Data(fields.joined(separator: "\n").utf8)
    }
}

/// One request as the phone signs it: what it sends, who sends it, its number and when.
struct SignedRequest: Equatable, Sendable {
    let method: String
    let path: String  // with the query, exactly as sent
    let deviceId: String
    let seq: Int
    let time: Int  // Unix seconds
    let body: Data
}
