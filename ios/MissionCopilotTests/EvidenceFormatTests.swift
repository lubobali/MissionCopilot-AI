import Foundation
import Testing
@testable import MissionCopilot

/// Payload v2 across languages (docs/evidence-format.md, #71). The Python side made a test chain with a
/// throwaway key (docs/api/fixtures/evidence-chain-v2.json): the app must produce exactly the same signed
/// bytes from the same fields, and must verify that chain with only the public key.
struct EvidenceFormatTests {
    struct Export: Decodable {
        let publicKeyDER: Data
        let records: [EvidenceRecord]
        let head: EvidenceRecord
    }

    static let fixture: Export = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/api/fixtures/evidence-chain-v2.json")
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Export.self, from: Data(contentsOf: url))
    }()

    @Test(.needsRepoFiles) func theAppEncodesTheSameFieldsToExactlyThePythonBytes() throws {
        for record in Self.fixture.records {
            let fields = try JSONDecoder().decode(EvidencePayload.self, from: record.payload)

            #expect(try EvidenceChain.encoder.encode(fields) == record.payload)
        }
    }

    @Test(.needsRepoFiles) func theAppVerifiesThePythonChainAndHeadWithOnlyThePublicKey() {
        let fixture = Self.fixture

        let result = EvidenceChain.verify(fixture.records, head: fixture.head, publicKeyDER: fixture.publicKeyDER)

        #expect(result == .valid(count: 3))
    }

    @Test(.needsRepoFiles) func noLocationMeansNoLocationFieldNotNull() throws {
        let payload = try JSONDecoder().decode(EvidencePayload.self, from: Self.fixture.records[1].payload)

        #expect(payload.location == nil)
        let text = String(bytes: try EvidenceChain.encoder.encode(payload), encoding: .utf8) ?? ""
        #expect(!text.isEmpty && !text.contains("location"))
    }

    @Test func captureTimeIsUTCInWholeSeconds() {
        let date = Date(timeIntervalSince1970: 1_794_476_467.9)  // 2026-11-12T09:41:07.9Z

        #expect(EvidenceChain.timestamp(date) == "2026-11-12T09:41:07Z")
    }

    @Test(arguments: [(12.3456784, 12_345_678), (12.3456786, 12_345_679), (-0.0000004, 0), (-89.9999996, -90_000_000)])
    func degreesBecomeWholeMicroDegrees(degrees: Double, micro: Int) {
        #expect(EvidencePayload.Location(latitude: degrees, longitude: degrees)
            == EvidencePayload.Location(latE6: micro, lonE6: micro))
    }
}
