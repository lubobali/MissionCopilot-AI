import CryptoKit
import Foundation
import GRDB

/// The pack as an evidence file (#162): the exact manifest bytes the server signed, their SHA-256, and the
/// server's signature document (nil for a pack imported before it was kept). Anyone can check the server's
/// signature over the manifest, and the manifest pins every pack file by its SHA-256.
struct PackEvidenceFile: Codable, Sendable, Equatable {
    let manifest: Data
    let manifestSHA256: String
    let signature: Data?
}

/// The finished site walk as an evidence file (#162): its answers and agreed-action checks as canonical JSON
/// (sorted keys, whole seconds, strings and integers only), so the same walk always gives the same bytes.
struct WalkEvidenceFile: Codable, Sendable, Equatable {
    struct Check: Codable, Sendable, Equatable {
        let seen: String
        let note: String?
        let photo: Int?
    }

    let formId: String
    let formVersion: String
    let finishedAt: Int
    let answers: [String: String]
    let checks: [String: Check]

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// Report sources as evidence (#162, decided A): the mission pack and the finished walk become items in the
/// mission's signed chain, once each, so facts written from them keep ADR 0009's one path to evidence.
extension MissionStore {
    struct WalkNotFinished: Error, Equatable { let mission: String }
    struct NoPack: Error, Equatable { let mission: String }

    /// The pack's evidence item: added once per manifest, then the same seq.
    @discardableResult
    func packEvidence(in mission: String, signer: any EvidenceSigner, now: Date = Date()) throws -> Int {
        guard let manifest = try packManifest(in: mission) else { throw NoPack(mission: mission) }
        let hash = PackAcceptance.hash(manifest)
        if let seq = try existing(.pack, in: mission, where: { (try? JSONDecoder().decode(
            PackEvidenceFile.self, from: $0))?.manifestSHA256 == hash }) {
            return seq
        }
        let file = PackEvidenceFile(manifest: manifest, manifestSHA256: hash, signature: try packSignature(in: mission))
        return try add(try WalkEvidenceFile.encoder.encode(file), kind: .pack, to: mission, signer: signer, now: now)
    }

    /// The finished walk's evidence item: refused before the finish, then added once.
    @discardableResult
    func walkEvidence(form: String, in mission: String, signer: any EvidenceSigner, now: Date = Date()) throws -> Int {
        guard let finished = try finishedWalk(form: form, mission: mission) else {
            throw WalkNotFinished(mission: mission)
        }
        if let seq = try existing(.walk, in: mission, where: { (try? JSONDecoder().decode(
            WalkEvidenceFile.self, from: $0))?.formId == form }) {
            return seq
        }
        let checks = try self.checks(mission: mission).mapValues {
            WalkEvidenceFile.Check(seen: $0.seen.rawValue, note: $0.note, photo: $0.photo)
        }
        let walk = WalkEvidenceFile(formId: form, formVersion: finished.version,
                                    finishedAt: Int(finished.finishedAt.timeIntervalSince1970),
                                    answers: try answers(form: form, mission: mission), checks: checks)
        return try add(try WalkEvidenceFile.encoder.encode(walk), kind: .walk, to: mission, signer: signer, now: now)
    }

    /// The exact manifest bytes kept with the mission's pack, or nil without a pack.
    func packManifest(in mission: String) throws -> Data? {
        let sealed = try store.read { database in
            try Data.fetchOne(database, sql: "SELECT sealed_manifest FROM mission_pack WHERE mission_id = ?",
                              arguments: [mission])
        }
        guard let sealed else { return nil }
        return try MissionData.open(sealed, with: missionKey(for: mission))
    }

    private func existing(_ kind: EvidencePayload.Kind, in mission: String,
                          where matches: (Data) -> Bool) throws -> Int? {
        for (index, record) in try evidence(in: mission).enumerated() {
            let payload = try? JSONDecoder().decode(EvidencePayload.self, from: record.payload)
            if payload?.kind == kind, matches(try evidenceFile(in: mission, seq: index + 1)) { return index + 1 }
        }
        return nil
    }

    private func add(_ file: Data, kind: EvidencePayload.Kind, to mission: String, signer: any EvidenceSigner,
                     now: Date) throws -> Int {
        let capture = Capture(file: file, kind: kind, capturedAt: now, clockSource: .device, location: nil)
        _ = try addEvidence(capture, to: mission, signer: signer)
        return try evidence(in: mission).count
    }
}
