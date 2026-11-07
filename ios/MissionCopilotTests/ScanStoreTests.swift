import Foundation
import GRDB
import Testing
import UIKit
@testable import MissionCopilot

/// Scanned pages as evidence (#138, step 6.5.2): each page re-encoded like a site photo (no metadata),
/// signed into the mission's chain as kind scan with the phone's key, sealed; the pages of one scan stay
/// together, in order (schema v14 `scan_page`), append-only, gone with their mission. Documents are not the
/// walk: a scan is still allowed after the walk is finished.
@MainActor
struct ScanStoreTests {
    let mission = "kandor-roads"

    private func store() throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        return store
    }

    static func page(_ width: Int = 1240, _ height: Int = 1754) throws -> UIImage {
        try #require(UIImage(data: try SitePhotoTests.cameraJPEG(width: width, height: height)))
    }

    private func payloads(_ store: MissionStore) throws -> [EvidencePayload] {
        try store.evidence(in: mission).map { try JSONDecoder().decode(EvidencePayload.self, from: $0.payload) }
    }

    @Test func eachPageIsSignedScanEvidenceAndTheScanKeepsThemInOrder() throws {
        let store = try store()

        let scan = try store.addScan([try Self.page(), try Self.page()], to: mission, signer: SoftwareEvidenceSigner(),
                                     now: SiteWalkTests.walkDay)

        let signed = try payloads(store)
        #expect(signed.map(\.kind) == [.scan, .scan])
        #expect(signed.allSatisfy { $0.location == nil })
        #expect(try store.scans(in: mission) == [scan])
        #expect(scan.pages == signed.map(\.seq))
    }

    @Test func aPageFileCarriesNoMetadata() throws {
        let store = try store()
        let scan = try store.addScan([try Self.page()], to: mission, signer: SoftwareEvidenceSigner())

        let file = try store.evidenceFile(in: mission, seq: try #require(scan.pages.first))

        let properties = try SitePhotoTests.properties(file)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
    }

    @Test func twoScansStaySeparateNewestLast() throws {
        let store = try store()
        let first = try store.addScan([try Self.page()], to: mission, signer: SoftwareEvidenceSigner())
        let second = try store.addScan([try Self.page(), try Self.page()], to: mission,
                                       signer: SoftwareEvidenceSigner())

        #expect(try store.scans(in: mission) == [first, second])
        #expect(second.pages.count == 2)
        #expect(first.id != second.id)
    }

    @Test func manyScansComeBackInTheOrderTheyWereMade() throws {
        // Six scans in the same second: a random order would match only 1 time in 720.
        let store = try store()
        var made: [DocumentScan] = []
        for _ in 0..<6 {
            made.append(try store.addScan([try Self.page(400, 600)], to: mission, signer: SoftwareEvidenceSigner(),
                                          now: SiteWalkTests.walkDay))
        }

        #expect(try store.scans(in: mission).map(\.id) == made.map(\.id))
    }

    @Test func noPagesAddsNothing() throws {
        let store = try store()

        #expect(throws: MissionStore.NoPages.self) {
            try store.addScan([], to: mission, signer: SoftwareEvidenceSigner())
        }
        #expect(try store.evidence(in: mission).isEmpty)
    }

    @Test func aScanIsStillAllowedAfterTheWalkIsFinished() throws {
        let store = try store()
        try store.finishWalk(form: SiteWalkStoreTests.form, version: "2026110401", mission: mission)

        let scan = try store.addScan([try Self.page()], to: mission, signer: SoftwareEvidenceSigner())

        #expect(scan.pages.count == 1)
    }

    @Test(arguments: ["UPDATE scan_page SET page = 9", "DELETE FROM scan_page"])
    func theDatabaseRefusesChangingAScan(sql: String) throws {
        let store = try store()
        try store.addScan([try Self.page()], to: mission, signer: SoftwareEvidenceSigner())

        #expect(throws: DatabaseError.self) { try store.store.rawExecuteForTests(sql) }
    }

    @Test func aScanGoesWithItsMission() throws {
        let store = try store()
        try store.addScan([try Self.page()], to: mission, signer: SoftwareEvidenceSigner())

        try store.reprovision(mission, at: Date())
        try store.create(mission: mission, title: "Kandor rural roads")

        #expect(try store.scans(in: mission).isEmpty)
    }

    @Test func theAuditLogNamesTheScanNeverItsText() throws {
        let store = try store()
        let scan = try store.addScan([try Self.page(), try Self.page()], to: mission, signer: SoftwareEvidenceSigner())

        let events = try store.store.auditEvents().filter { $0.action == .documentScanned }

        #expect(events.map(\.target) == ["\(scan.id) 2 pages"])
    }
}
