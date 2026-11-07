import Foundation
import GRDB

/// A kept voice debrief: its signed audio evidence, length and language.
struct Debrief: Sendable, Equatable, Identifiable {
    let seq: Int
    let seconds: Double
    let language: SpeechLanguage
    let recordedAt: Date
    var id: Int { seq }
}

extension MissionStore {
    struct EmptyRecording: Error {}

    /// The recording signed into the mission's chain as kind audio with the phone's key (no place: a debrief
    /// is not a site photo), sealed with the mission key, then the debrief recorded. The temporary file is
    /// deleted once the sealed copy is stored. A finished walk does not stop a debrief.
    @discardableResult
    func addDebrief(_ recording: Recording, language: SpeechLanguage, to mission: String,
                    signer: any EvidenceSigner, now: Date = Date()) throws -> Debrief {
        let audio = try Data(contentsOf: recording.file)
        guard !audio.isEmpty else { throw EmptyRecording() }
        let record = try addEvidence(Capture(file: audio, kind: .audio, capturedAt: now, clockSource: .device,
                                             location: nil), to: mission, signer: signer)
        let seq = try JSONDecoder().decode(EvidencePayload.self, from: record.payload).seq
        // The time as the store keeps it (seconds since 1970), so a debrief read back is equal to this one.
        let debrief = Debrief(seq: seq, seconds: min(recording.seconds, DebriefModel.limit), language: language,
                              recordedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970))
        try store.write { database in
            try database.execute(sql: "INSERT INTO debrief VALUES (?, ?, ?, ?, ?)",
                                 arguments: [mission, seq, debrief.seconds, language.rawValue,
                                             debrief.recordedAt.timeIntervalSince1970])
            try EncryptedStore.appendAudit(AuditEntry(action: .debriefRecorded, actor: actor, mission: mission,
                                                      target: "\(seq) \(Int(debrief.seconds)) s \(language.rawValue)",
                                                      time: now), in: database)
        }
        try? FileManager.default.removeItem(at: recording.file)
        return debrief
    }

    /// The mission's debriefs in the order they were recorded.
    func debriefs(in mission: String) throws -> [Debrief] {
        try store.read { database in
            try Row.fetchAll(database, sql: """
                SELECT evidence_seq, seconds, language, recorded_at FROM debrief WHERE mission_id = ? ORDER BY rowid
                """, arguments: [mission]).compactMap { row in
                SpeechLanguage(rawValue: row["language"]).map { language in
                    Debrief(seq: row["evidence_seq"], seconds: row["seconds"], language: language,
                            recordedAt: Date(timeIntervalSince1970: row["recorded_at"]))
                }
            }
        }
    }
}
