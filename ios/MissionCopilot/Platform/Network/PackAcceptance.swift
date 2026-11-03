import CryptoKit
import Foundation

/// The last mission pack this phone accepted for a mission: its version and the SHA-256 of its manifest.
struct AcceptedPack: Equatable, Sendable {
    let version: Int
    let manifestSHA256: String
}

/// Freshness and rollback (#91, threat T51), after PackVerifier: the pack must be for the mission and
/// organization the phone asked for, and its version above the last one accepted for that mission, so an
/// older (genuinely signed) pack cannot be played back. The same version is fine only with the same
/// manifest bytes: fetching it again. The last accepted pack is kept in the encrypted mission store.
enum PackAcceptance {
    static func check(_ pack: PackManifest, manifestBytes: Data, asked: (org: String, mission: String),
                      in store: MissionStore) throws(PackRefusal) {
        guard pack.orgId == asked.org, pack.missionId == asked.mission else { throw .wrongMission }
        try versionRule(pack, manifestBytes: manifestBytes, last: try lastAccepted(pack.missionId, in: store))
    }

    /// Above the last accepted version; the same version only with the same bytes (fetching it again).
    static func versionRule(_ pack: PackManifest, manifestBytes: Data, last: AcceptedPack?) throws(PackRefusal) {
        guard let last else { return }
        if pack.version < last.version { throw .older }
        if pack.version == last.version, hash(manifestBytes) != last.manifestSHA256 { throw .replaced }
    }

    /// After the whole pack is in the store: remember it. Never moves the version back.
    static func record(_ pack: PackManifest, manifestBytes: Data, in store: MissionStore) throws(PackRefusal) {
        if let last = try lastAccepted(pack.missionId, in: store), pack.version < last.version {
            throw .older
        }
        do {
            try store.recordAcceptedPack(AcceptedPack(version: pack.version, manifestSHA256: hash(manifestBytes)),
                                         for: pack.missionId)
        } catch {
            throw .storeUnavailable
        }
    }

    /// Fails closed: a store that cannot be read is not "nothing accepted yet".
    private static func lastAccepted(_ mission: String, in store: MissionStore) throws(PackRefusal) -> AcceptedPack? {
        do {
            return try store.lastAcceptedPack(for: mission)
        } catch {
            throw .storeUnavailable
        }
    }

    static func hash(_ data: Data) -> String { PackVerifier.hex(SHA256.hash(data: data)) }
}

extension MissionStore {
    static func acceptedKey(_ mission: String) -> String { "pack.accepted.\(mission)" }

    static func acceptedPack(_ value: String?) -> AcceptedPack? {
        let parts = value?.split(separator: " ") ?? []
        guard parts.count == 2, let version = Int(parts[0]) else { return nil }
        return AcceptedPack(version: version, manifestSHA256: String(parts[1]))
    }

    func lastAcceptedPack(for mission: String) throws -> AcceptedPack? {
        Self.acceptedPack(try store.info(Self.acceptedKey(mission)))
    }

    func recordAcceptedPack(_ pack: AcceptedPack, for mission: String) throws {
        try store.setInfo(Self.acceptedKey(mission), "\(pack.version) \(pack.manifestSHA256)")
    }
}
