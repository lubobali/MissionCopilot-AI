import CryptoKit
import Foundation

/// Checks a shred order before the phone acts on it (ADR 0012, #60, threat T18). The server answers a
/// revoked phone's signed request with a 410 whose body carries the order and the server's signature
/// over exactly "missioncopilot-shred-v1", newline, then device id, scope and time, one per line
/// (shred_order.shred_message). The order is accepted only if it is that kind of order, a pinned key
/// signed those exact bytes, it names this phone, and it was issued within five minutes (the server's
/// own window), so an old captured order cannot be played back later.
enum ShredOrderCheck {
    enum Refusal: Equatable, Sendable { case notAnOrder, badSignature, otherPhone, notRecent }
    enum Verdict: Equatable, Sendable { case valid(issuedAt: Int), refused(Refusal) }

    static let problemType = "urn:missioncopilot:problem:shred-order"
    static let scope = "all-missions"
    static let window = 300  // seconds, as the server allows for a request
    static let domain = Data("missioncopilot-shred-v1\n".utf8)

    private struct Body: Decodable { let type: String, order: ShredOrderFields, signature: String }

    static func message(deviceId: String, scope: String, issuedAt: Int) -> Data {
        domain + Data([deviceId, scope, String(issuedAt)].joined(separator: "\n").utf8)
    }

    static func check(_ body: Data, deviceId: String, keys: [P256.Signing.PublicKey], now: Date) -> Verdict {
        guard let found = try? JSONDecoder().decode(Body.self, from: body), found.type == problemType,
              found.order.scope == scope else { return .refused(.notAnOrder) }
        let order = found.order
        let message = message(deviceId: order.deviceId, scope: order.scope, issuedAt: order.issuedAt)
        guard let raw = Data(base64Encoded: found.signature),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: raw),
              keys.contains(where: { $0.isValidSignature(signature, for: message) }) else {
            return .refused(.badSignature)
        }
        guard order.deviceId == deviceId else { return .refused(.otherPhone) }
        guard abs(Int(now.timeIntervalSince1970) - order.issuedAt) <= window else { return .refused(.notRecent) }
        return .valid(issuedAt: order.issuedAt)
    }
}

/// The order's own fields, as the server writes them.
private struct ShredOrderFields: Decodable { let deviceId: String, scope: String, issuedAt: Int }

/// Acts on a shred order only after ShredOrderCheck accepts it: every mission still readable is
/// destroyed (reason: shred order) and recorded, and the phone forgets its enrollment, since it was
/// revoked. With the store closed there is nothing readable to destroy; the enrollment is still
/// forgotten, and the missions follow when their leases end.
enum ShredOrderAction {
    enum Result: Equatable, Sendable { case destroyed(Int), ignored(ShredOrderCheck.Refusal) }

    /// This phone's identity: its enrollment record and the way to delete its chip key. Both go in a shred
    /// (#94): the server never takes a key it already knows, a revoked one included, so a shredded phone
    /// that kept its key could never connect again.
    struct Phone {
        let records: DeviceRecordStore
        let forgetKey: () -> Void
    }

    static func handle(_ body: Data, phone: Phone, missions: MissionStore?,
                       keys: [P256.Signing.PublicKey], now: Date) -> Result {
        let records = phone.records
        let deviceId = records.load()?.deviceId ?? ""
        if case .refused(let why) = ShredOrderCheck.check(body, deviceId: deviceId, keys: keys, now: now) {
            return .ignored(why)
        }
        let destroyed = (try? missions?.shredAll(reason: .shredOrder, at: now, policy: FieldPolicy()))?.count ?? 0
        try? records.items.delete(records.user)
        phone.forgetKey()
        return .destroyed(destroyed)
    }
}
