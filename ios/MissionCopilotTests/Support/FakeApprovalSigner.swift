import CryptoKit
import Foundation
@testable import MissionCopilot

/// A software stand-in for the approval key (the Secure Enclave is not in the Simulator): it counts its
/// signatures and can act as if the officer cancelled or Face ID failed.
final class FakeApprovalSigner: ApprovalSigner, @unchecked Sendable {
    enum Then { case sign, cancel, fail }

    private let key = P256.Signing.PrivateKey()
    private let lock = NSLock()
    private var then: Then
    private(set) var reasons: [String] = []

    init(_ then: Then = .sign) { self.then = then }

    var signatures: Int { lock.withLock { reasons.count } }

    func publicKeyDER() throws -> Data { key.publicKey.derRepresentation }

    func sign(_ payload: Data, reason: String) async throws -> Data {
        lock.withLock { reasons.append(reason) }
        switch lock.withLock({ then }) {
        case .sign: return try key.signature(for: payload).derRepresentation
        case .cancel: throw NSError(domain: "com.apple.LocalAuthentication", code: -2)
        case .fail: throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed))
        }
    }
}
