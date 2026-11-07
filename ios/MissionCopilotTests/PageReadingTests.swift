import Foundation
import GRDB
import Testing
import UIKit
@testable import MissionCopilot

/// Reading a scanned page on the phone (#138, step 6.5.3): Apple Vision (`RecognizeDocumentsRequest`)
/// reads the page's sealed evidence file, text and tables, offline; the reading is stored sealed with its
/// page (schema v15 `page_reading`), once per page and reader version, append-only, gone with its mission.
/// The demo pages go the real way: scanned, re-encoded, signed, sealed, opened, read.
struct AnswerPage: Decodable { let lines: [String] }

@MainActor
struct PageReadingTests {
    let mission = "kandor-roads"

    static let scans = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/demo/scans")

    struct AnswerKey: Decodable {
        let pages: [String: AnswerPage]
    }

    static func demo(_ name: String) throws -> UIImage {
        try #require(UIImage(data: try Data(contentsOf: scans.appendingPathComponent("\(name).png"))))
    }

    static func lines(_ name: String) throws -> [String] {
        let key = try JSONDecoder().decode(AnswerKey.self,
                                           from: Data(contentsOf: scans.appendingPathComponent("answer-key.json")))
        return try #require(key.pages[name]).lines
    }

    private func store() throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        return store
    }

    private static func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test(arguments: ["invoice-14", "progress-report-2026-09"])
    func aScannedDemoPageIsReadWithEveryLineOfItsAnswerKey(name: String) async throws {
        let store = try store()
        let scan = try store.addScan([try Self.demo(name)], to: mission, signer: SoftwareEvidenceSigner())

        let reading = try await store.readPage(try #require(scan.pages.first), in: mission)

        let text = Self.flat(reading.transcript)
        for line in try Self.lines(name) {
            #expect(text.contains(Self.flat(line)), "missing: \(line)")
        }
        #expect(reading.reader == PageReading.currentReader)
    }

    @Test func theInvoicesPaymentTableIsReadAsCells() async throws {
        let store = try store()
        let scan = try store.addScan([try Self.demo("invoice-14")], to: mission, signer: SoftwareEvidenceSigner())

        let reading = try await store.readPage(try #require(scan.pages.first), in: mission)

        let cells = reading.tables.flatMap { $0.flatMap { $0 } }
        #expect(cells.contains("Invoice 13"))
        #expect(cells.contains { $0.contains("480,000") })
    }

    @Test func theReadingIsStoredSealedAndReadOnlyOnce() async throws {
        let store = try store()
        let scan = try store.addScan([try Self.demo("invoice-14")], to: mission, signer: SoftwareEvidenceSigner())
        let seq = try #require(scan.pages.first)

        let first = try await store.readPage(seq, in: mission)
        let second = try await store.readPage(seq, in: mission)

        #expect(first == second)
        let rows = try store.store.read { try Data.fetchAll($0, sql: "SELECT sealed_reading FROM page_reading") }
        #expect(rows.count == 1, "read once, then kept")
        #expect(!rows[0].contains(Data("480,000".utf8)) && !rows[0].contains(Data("Invoice".utf8)))
        #expect(try store.reading(of: seq, in: mission) == first)
    }

    @Test func aPageThatIsNotAScanIsNotRead() async throws {
        let store = try store()
        let photo = Capture(file: try SitePhoto.prepare(try Self.demo("invoice-14")), kind: .photo,
                            capturedAt: SiteWalkTests.walkDay, clockSource: .device, location: nil)
        let record = try store.addEvidence(photo, to: mission, signer: SoftwareEvidenceSigner())
        let seq = try JSONDecoder().decode(EvidencePayload.self, from: record.payload).seq

        await #expect(throws: MissionStore.NotAScan.self) { try await store.readPage(seq, in: mission) }
    }

    @Test(arguments: ["UPDATE page_reading SET reader = 'x'", "DELETE FROM page_reading"])
    func theDatabaseRefusesChangingAReading(sql: String) async throws {
        let store = try store()
        let scan = try store.addScan([try Self.demo("invoice-14")], to: mission, signer: SoftwareEvidenceSigner())
        _ = try await store.readPage(try #require(scan.pages.first), in: mission)

        #expect(throws: DatabaseError.self) { try store.store.rawExecuteForTests(sql) }
    }
}
