import Foundation
import GRDB
import Testing
@testable import MissionCopilot

/// Confirm and store (#138, step 6.5.9): the officer confirms or corrects each of the 8 facts, and only then
/// are they stored, all in one write. A confirmed fact cites its page's evidence and its position in that
/// page's reading (rule scan-invoice v1); a corrected one is the officer's (rule officer v1), citing the
/// pages it was read from. A fact the pages do not print cannot be confirmed (ADR 0009). The audit names
/// the fact, never its value.
@MainActor
struct FactConfirmTests {
    let mission = "kandor-roads"

    /// A store with the two Kandor pages scanned (evidence 1 and 2) and the review of the true facts.
    struct Scanned {
        let store: MissionStore
        let review: FactReview
        let pages: [Int]
    }

    private func scanned() throws -> Scanned {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        let scan = try store.addScan([try ScanStoreTests.page(), try ScanStoreTests.page()], to: mission,
                                     signer: SoftwareEvidenceSigner())
        let review = try InvoiceChecksTests.review(FactGroundingTests.truth)
        return Scanned(store: store, review: review, pages: scan.pages)
    }

    static let confirmAll = Dictionary(uniqueKeysWithValues: InvoiceFacts.fields.map { ($0, FactDecision.confirm) })

    @Test func confirmedFactsAreStoredWithTheirPageAndPosition() throws {
        let scanned = try scanned()
        let (store, review, pages) = (scanned.store, scanned.review, scanned.pages)

        let facts = try store.confirmFacts(review, decisions: Self.confirmAll, pages: pages, in: mission)

        #expect(try store.facts(in: mission) == facts)
        #expect(facts.map(\.name) == InvoiceFacts.fields)
        #expect(facts.map(\.value) == ["14", "2026-10-12", "480000", "8500000", "10000000", "32", "64",
                                       "not_started"])
        #expect(facts.map(\.unit) == [nil, nil, "USD", "USD", "USD", "km", "km", nil])
        #expect(facts.allSatisfy { $0.rule == RuleRef(id: "scan-invoice", version: "1") })
        let amount = try #require(facts.first { $0.name == "amountDue" })
        let printed = try #require(review.printedAt["amountDue"])
        #expect(amount.sources == [FactSource(seq: pages[0], region: printed.region)])
        #expect(facts.first { $0.name == "kmTotal" }?.sources.map(\.seq) == [pages[1]])
    }

    @Test func aRegionPointsBackIntoThePageReading() throws {
        let reading = try FactGroundingTests.kandorPages()[0]
        let printed = try #require(FactGrounding.sources(FactGroundingTests.truth, in: [reading])["cumulativePaid"])

        #expect(printed.region == "vision-recognize-documents-1 text \(printed.offset)+9")
        #expect(FactGrounding.printed(printed.region, in: reading) == "8,500,000")
        #expect(FactGrounding.printed("another-reader text \(printed.offset)+9", in: reading) == nil)
        #expect(FactGrounding.printed("vision-recognize-documents-1 text 99999+3", in: reading) == nil)
        #expect(FactGrounding.printed("nonsense", in: reading) == nil)
    }

    @Test func aCorrectedFactIsTheOfficersCitingEveryPage() throws {
        let scanned = try scanned()
        let (store, review, pages) = (scanned.store, scanned.review, scanned.pages)
        var decisions = Self.confirmAll
        decisions["kmCompleted"] = .correct("30")

        let facts = try store.confirmFacts(review, decisions: decisions, pages: pages, in: mission)

        let corrected = try #require(facts.first { $0.name == "kmCompleted" })
        #expect(corrected.value == "30")
        #expect(corrected.rule == RuleRef(id: "officer", version: "1"))
        #expect(corrected.sources == pages.map { FactSource(seq: $0, region: nil) })
    }

    @Test func nothingIsStoredUntilEveryFactIsDecided() throws {
        let scanned = try scanned()
        let (store, review, pages) = (scanned.store, scanned.review, scanned.pages)
        var decisions = Self.confirmAll
        decisions["bridgeStatus"] = nil
        decisions["kmTotal"] = nil

        #expect(throws: MissionStore.FactsNotDecided(fields: ["kmTotal", "bridgeStatus"])) {
            try store.confirmFacts(review, decisions: decisions, pages: pages, in: self.mission)
        }
        #expect(try store.facts(in: mission).isEmpty)
    }

    @Test func aFactThePagesDoNotPrintCannotBeConfirmedOnlyCorrected() throws {
        let scanned = try scanned()
        let (store, pages) = (scanned.store, scanned.pages)
        let review = try InvoiceChecksTests.review(InvoiceChecksTests.facts(road: (33, 64)))

        #expect(throws: MissionStore.CannotConfirm(field: "kmCompleted")) {
            try store.confirmFacts(review, decisions: Self.confirmAll, pages: pages, in: self.mission)
        }
        #expect(try store.facts(in: mission).isEmpty)

        var decisions = Self.confirmAll
        decisions["kmCompleted"] = .correct("32")
        #expect(try store.confirmFacts(review, decisions: decisions, pages: pages, in: mission).count == 8)
    }

    @Test func anEmptyCorrectionOrAMissingPageIsRefused() throws {
        let scanned = try scanned()
        let (store, review, pages) = (scanned.store, scanned.review, scanned.pages)
        var decisions = Self.confirmAll
        decisions["amountDue"] = .correct("  ")

        #expect(throws: MissionStore.CannotConfirm(field: "amountDue")) {
            try store.confirmFacts(review, decisions: decisions, pages: pages, in: self.mission)
        }
        #expect(throws: MissionStore.CannotConfirm(field: "kmCompleted")) {
            try store.confirmFacts(review, decisions: Self.confirmAll, pages: [pages[0]], in: self.mission)
        }
        #expect(try store.facts(in: mission).isEmpty)
    }

    @Test func theSamePagesAreConfirmedOnce() throws {
        let scanned = try scanned()
        let (store, review, pages) = (scanned.store, scanned.review, scanned.pages)
        try store.confirmFacts(review, decisions: Self.confirmAll, pages: pages, in: mission)

        #expect(throws: MissionStore.AlreadyConfirmed.self) {
            try store.confirmFacts(review, decisions: Self.confirmAll, pages: pages, in: self.mission)
        }
        #expect(try store.facts(in: mission).count == 8)
    }

    @Test func theAuditNamesEachFactNeverItsValueAndValuesAreSealed() throws {
        let scanned = try scanned()
        let (store, review, pages) = (scanned.store, scanned.review, scanned.pages)

        let facts = try store.confirmFacts(review, decisions: Self.confirmAll, pages: pages, in: mission)

        let added = try store.store.auditEvents().filter { $0.action == .factAdded }
        #expect(added.map(\.target) == facts.map(\.id))
        #expect(!added.contains { ($0.target ?? "").contains("8500000") || ($0.target ?? "").contains("480000") })
        #expect(try store.store.verifyAudit() == .valid(count: try store.store.auditEvents().count))
        #expect(try store.sealedFactValues(in: mission).allSatisfy { !$0.contains(Data("8500000".utf8)) })
    }
}
