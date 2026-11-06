import Foundation

/// One signed photo: its mission and its place in that mission's evidence chain.
struct PhotoRef: Codable, Sendable, Equatable, Hashable {
    let mission: String
    let seq: Int
}

/// What MC-04 reads (#134): this mission's photos, every photo on this phone that shares their bytes, and
/// the missions that could not be read (shredded: their key is gone).
struct PhotoReuseCheck: Sendable, Equatable {
    /// This mission's photos, in chain order.
    let photos: [PhotoRef]
    /// For each of this mission's photo hashes, every photo on the phone with it, this mission first.
    let sameBytes: [String: [PhotoRef]]
    let skipped: [String]
}

extension MissionStore {
    /// Compares the signed content hash (SHA-256 of the photo's bytes), so only an exact copy matches.
    func photoReuse(for mission: String) throws -> PhotoReuseCheck {
        var skipped: [String] = []
        var byHash: [String: [PhotoRef]] = [:]
        var mine: [PhotoRef] = []
        let others = try missionIDs().filter { $0 != mission }
        for id in [mission] + others {
            // Only a key that cannot be opened (a shredded mission) is skipped; any other error stops the check.
            if id != mission, (try? missionKey(for: id)) == nil {
                skipped.append(id)
                continue
            }
            for record in try evidence(in: id) {
                let payload = try JSONDecoder().decode(EvidencePayload.self, from: record.payload)
                guard payload.kind == .photo else { continue }
                let ref = PhotoRef(mission: id, seq: payload.seq)
                byHash[payload.contentHash, default: []].append(ref)
                if id == mission { mine.append(ref) }
            }
        }
        let myHashes = Set(byHash.filter { $0.value.contains { $0.mission == mission } }.keys)
        return PhotoReuseCheck(photos: mine, sameBytes: byHash.filter { myHashes.contains($0.key) }, skipped: skipped)
    }
}
