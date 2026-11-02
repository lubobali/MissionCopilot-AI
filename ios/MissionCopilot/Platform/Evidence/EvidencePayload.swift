import Foundation

/// One signed record: the exact bytes that were signed, and the DER signature over them. Verifiers
/// check these bytes as stored and never re-encode the JSON, so Swift and Python always agree.
struct EvidenceRecord: Codable, Sendable, Equatable {
    let payload: Data
    let signature: Data
}

/// What the phone signs for each photo, scanned page or recording: payload version 2
/// (docs/evidence-format.md). Encoded with sorted keys and integers only; a nil location is left out.
struct EvidencePayload: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case photo, scan, audio }
    enum ClockSource: String, Codable, Sendable { case device, gnss }

    /// Whole micro-degrees: no decimals in signed bytes, so both languages print the same.
    struct Location: Codable, Sendable, Equatable {
        let latE6: Int
        let lonE6: Int

        init(latE6: Int, lonE6: Int) {
            self.latE6 = latE6
            self.lonE6 = lonE6
        }

        init(latitude: Double, longitude: Double) {
            self.init(latE6: Int((latitude * 1_000_000).rounded()), lonE6: Int((longitude * 1_000_000).rounded()))
        }
    }

    var version = 2
    let seq: Int
    let prevHash: String
    let contentHash: String
    let kind: Kind
    let capturedAt: String
    let clockSource: ClockSource
    let location: Location?
    let missionId: String

    /// "v" in the signed bytes, as the format and the Python verifier name it.
    enum CodingKeys: String, CodingKey {
        case version = "v", seq, prevHash, contentHash, kind, capturedAt, clockSource, location, missionId
    }
}

/// What the camera, scanner or recorder hands over to be signed.
struct Capture: Sendable {
    let file: Data
    let kind: EvidencePayload.Kind
    let capturedAt: Date
    let clockSource: EvidencePayload.ClockSource
    let location: EvidencePayload.Location?
}
