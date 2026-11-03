import Foundation

/// What sending the one-time code can give.
enum EnrollmentResult: Equatable, Sendable {
    case enrolled(deviceId: String)
    case badCode  // unknown, used, expired or mistyped: ask the admin for a new one
    case slowDown(Int)
    case offline
    case failed
}

/// Connects this iPhone to its organization (docs/security.md, #90): the admin's one-time code, the chip
/// key's public half and a proof signed by its private half (DeviceSigning.enrollmentMessage). The only
/// request that is not signed as a device: the code is what proves it. A code that cannot be right is
/// never sent.
struct Enroller: Sendable {
    let base: URL
    let signer: EvidenceSigner
    var transport: Transport = URLSessionTransport()
    var allowLocalHTTP = false

    private struct Body: Encodable { let code: String, publicKeyDER: String, proof: String }
    private struct Answer: Decodable { let id: String }

    static func looksRight(_ code: String) -> Bool {
        (16...64).contains(code.count) && code.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "-" || scalar == "_"
        }
    }

    func enroll(code typed: String) async -> EnrollmentResult {
        let code = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksRight(code), ServerClient.allowed(base, local: allowLocalHTTP),
              let url = URL(string: base.absoluteString + "/v1/devices/enroll") else { return .badCode }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let key = try signer.publicKeyDER()
            let proof = try signer.sign(DeviceSigning.enrollmentMessage(code: code, publicKeyDER: key))
            request.httpBody = try JSONEncoder().encode(Body(code: code, publicKeyDER: key.base64EncodedString(),
                                                             proof: proof.base64EncodedString()))
        } catch {
            return .failed
        }
        switch await ServerClient.outcome({ try await transport.send(request) }) {
        case .success(let data, _, _):
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return .failed }
            return .enrolled(deviceId: answer.id)
        case .refused: return .badCode
        case .slowDown(let seconds): return .slowDown(seconds)
        case .offline: return .offline
        default: return .failed
        }
    }
}

/// This phone's enrollment for one user, kept in the Keychain (this device only): its device id, and
/// whether a manager has approved it.
struct DeviceRecord: Codable, Equatable, Sendable {
    let deviceId: String
    var approved: Bool
}

struct DeviceRecordStore: Sendable {
    let items: KeychainItems
    let user: String

    init(service: String = "com.lubobali.missioncopilot.device", user: String) {
        items = KeychainItems(service: service)
        self.user = user
    }

    func load() -> DeviceRecord? {
        guard let data = try? items.load(user) else { return nil }
        return try? JSONDecoder().decode(DeviceRecord.self, from: data)
    }

    func save(_ record: DeviceRecord) throws {
        let data = try JSONEncoder().encode(record)
        if try items.update(data, account: user) { return }
        _ = try items.add(data, account: user, access: ChipKeyAccess.blob())
    }
}
