import CryptoKit
import Foundation

/// Why a mission pack is not used. The same reasons as the server's pack_format, plus one only the phone
/// can know (the app is older than the pack needs).
enum PackRefusal: Error, Equatable, Sendable {
    case unknownKey, badSignature, malformed, keyMismatch, expired, appTooOld, wrongSize, wrongHash
    /// Not the mission and organization asked for; older than the last one accepted (a rollback); the
    /// same version as the last one but other content.
    case wrongMission, older, replaced
    /// The store could not say what was accepted before (paused while locked): refuse, never assume.
    case storeUnavailable
    /// A section or the checklist is missing or does not match the pack sections schema (#92).
    case badSection
    /// The checklist passes the schema but no one could fill it: ChecklistForm refuses it (#93, T54).
    case badChecklist
}

struct PackFileEntry: Equatable, Sendable {
    let path: String, sha256: String, size: Int, mediaType: String
}

struct PackManifest: Equatable, Sendable {
    let packId: String, orgId: String, missionId: String, version: Int
    let createdAt: Date, expiresAt: Date, minAppVersion: String, keyId: String
    let files: [PackFileEntry]
}

/// The phone's checks on a mission pack (API contract MissionPack, threat T51, #91), the same as the
/// server's pack_format.verify_pack: a pinned key signed "missioncopilot-pack-v1", newline, then the exact
/// manifest bytes (never re-encoded); the contract's rules hold even after a genuine signature (it proves
/// who wrote the manifest, not that it is safe); the key id inside matches; it has not expired; and this
/// app is at least the version the pack needs. Each downloaded file must then match its size and hash.
enum PackVerifier {
    static let domain = Data("missioncopilot-pack-v1\n".utf8)
    static let algorithm = "ecdsa-p256-sha256"

    /// This build's version (CFBundleShortVersionString).
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private struct Signature: Decodable { let keyId: String, algorithm: String, signature: String }

    static func verify(manifest: Data, signature: Data, keys: (String) -> P256.Signing.PublicKey?, now: Date,
                       appVersion: String = appVersion) throws(PackRefusal) -> PackManifest {
        guard let found = try? JSONDecoder().decode(Signature.self, from: signature) else { throw .badSignature }
        guard let key = keys(found.keyId) else { throw .unknownKey }
        guard found.algorithm == algorithm, let raw = Data(base64Encoded: found.signature), !raw.isEmpty,
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: raw),
              key.isValidSignature(parsed, for: domain + manifest) else { throw .badSignature }
        guard let object = try? JSONSerialization.jsonObject(with: manifest) else { throw .malformed }
        let pack = try rules(object)
        guard pack.keyId == found.keyId else { throw .keyMismatch }
        guard now < pack.expiresAt else { throw .expired }
        guard isAtLeast(appVersion, pack.minAppVersion) else { throw .appTooOld }
        return pack
    }

    /// A downloaded file must be exactly what its manifest entry says.
    static func check(_ entry: PackFileEntry, data: Data) throws(PackRefusal) {
        guard data.count == entry.size else { throw .wrongSize }
        guard hex(SHA256.hash(data: data)) == entry.sha256 else { throw .wrongHash }
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// "0.10.0" is newer than "0.5": numbers compared part by part, missing parts are 0.
    static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        let have = version.split(separator: ".").map { Int($0) ?? 0 }
        let need = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(have.count, need.count) {
            let left = index < have.count ? have[index] : 0, right = index < need.count ? need[index] : 0
            if left != right { return left > right }
        }
        return true
    }
}
