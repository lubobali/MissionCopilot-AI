import CryptoKit
import Foundation

/// Tells the server this phone's Face ID approval key (#171, step 8.1.2), so a sync can check the officer's
/// approvals (#172). Only an approved phone sends it; reading the public key asks no Face ID. Once the server
/// answers with the same key id, the device record keeps it and nothing is sent again; offline, refused or busy
/// keeps nothing, so the next try sends again (the server answers the same record: safe to repeat).
struct ApprovalKeyRegistration: Sendable {
    enum Result: Equatable, Sendable { case registered, alreadyKnown, notYet }

    static let path = "/v1/devices/me/approval-key"

    let signer: any ApprovalSigner
    let records: DeviceRecordStore

    /// The key's id, as the server names it: the SHA-256 of its SubjectPublicKeyInfo DER, in hex.
    static func keyId(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private struct Sent: Encodable { let publicKeyDER: String }
    private struct Kept: Decodable { let keyId: String }

    func ensure(client: ServerClient) async -> Result {
        guard var record = records.load(), record.approved, let der = try? signer.publicKeyDER() else {
            return .notYet
        }
        let id = Self.keyId(der)
        if record.approvalKeyId == id { return .alreadyKnown }
        guard let body = try? JSONEncoder().encode(Sent(publicKeyDER: der.base64EncodedString())),
              case .success(let data, let status, _) = await client.post(Self.path, body: body),
              status == 200 || status == 201,
              (try? JSONDecoder().decode(Kept.self, from: data))?.keyId == id else { return .notYet }
        record.approvalKeyId = id
        guard (try? records.save(record)) != nil else { return .notYet }
        return .registered
    }
}
