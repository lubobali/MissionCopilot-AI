import Foundation
import Testing
@testable import MissionCopilot

/// Red flags from the confirmed invoice facts (#138, step 6.5.10): R068 (paid against the contract value) and
/// MC-01 (paid ahead of built) also run on what the officer confirmed from the scanned pages, each such result
/// citing the facts it used. The pack's own results stay exactly as they are, first, in the rules' order.
struct ScannedFlagsTests {
    static func fact(_ name: String, _ value: String, rule: RuleRef = MissionStore.scanRule) -> Fact {
        Fact(id: "f-\(name)-\(value)", name: name, value: value, unit: nil, rule: rule,
             classification: .officialUseOnly, sources: [FactSource(seq: 1, region: nil)])
    }

    /// The 8 facts as confirmFacts stores them, in field order.
    static func confirmed(_ facts: InvoiceFacts = FactGroundingTests.truth) -> [Fact] {
        InvoiceFacts.fields.map { fact($0, facts.value($0) ?? "") }
    }

    static func kandor(scanned: [ScannedInvoice]?) throws -> [RedFlagResult] {
        var inputs = RedFlagInputs(contracts: try PackContracts.read(try PackFiguresTests.file(PackContracts.path)),
                                   milestones: try PackMilestones.read(try PackFiguresTests.file(PackMilestones.path)))
        inputs.scanned = scanned
        return RedFlagEngine(rules: RedFlagEngineTests.rules).run(inputs, walk: SiteWalkTests.walkDay, timeZone: .gmt)
    }

    @Test func theConfirmedFactsBecomeAScannedInvoice() throws {
        let invoices = ScannedInvoice.all(from: Self.confirmed())

        #expect(invoices.count == 1)
        let invoice = try #require(invoices.first)
        #expect(invoice.number == "14")
        #expect(invoice.paid == 8_500_000)
        #expect(invoice.contractValue == 10_000_000)
        #expect(invoice.kmBuilt == 32 && invoice.kmTotal == 64)
        #expect(invoice.facts["cumulativePaid"] == FactRef(id: "f-cumulativePaid-8500000", name: "cumulativePaid"))
    }

    @Test func eachConfirmationIsItsOwnInvoiceAndOnlyWholeOnesCount() {
        let second = InvoiceChecksTests.facts(cumulativePaid: 9_000_000)
        let other = Self.fact("note", "x", rule: RuleRef(id: "debrief", version: "1"))
        var corrected = Self.confirmed(second)
        corrected[5] = Self.fact("kmCompleted", "40", rule: MissionStore.officerRule)

        // A fact from another rule, even with a scanned fact's name, is never part of an invoice.
        let otherPaid = Self.fact("cumulativePaid", "1", rule: RuleRef(id: "debrief", version: "1"))
        corrected.insert(otherPaid, at: 1)

        let invoices = ScannedInvoice.all(from: Self.confirmed() + [other] + corrected
                                          + Array(Self.confirmed().prefix(3)))

        #expect(invoices.map(\.paid) == [8_500_000, 9_000_000])
        #expect(invoices.map(\.kmBuilt) == [32, 40])
    }

    @Test func aFactThatIsNotANumberMakesNoInvoice() {
        var facts = Self.confirmed()
        facts[3] = Self.fact("cumulativePaid", "8.5 million")

        #expect(ScannedInvoice.all(from: facts).isEmpty)
    }

    @Test func onKandorTheScannedInvoiceAddsOneResultToR068AndMC01() throws {
        let pack = try Self.kandor(scanned: nil)
        let both = try Self.kandor(scanned: ScannedInvoice.all(from: Self.confirmed()))

        #expect(both.map(\.rule.id) == ["R068", "R068", "R067", "MC-01", "MC-01", "MC-02", "MC-03", "MC-04"])
        #expect(both.filter { $0.subject != "Scanned invoice 14" } == pack)
        let scanned = both.filter { $0.subject == "Scanned invoice 14" }
        #expect(scanned.map(\.outcome) == [.clear, .flag])
        #expect(scanned.map(\.computed) == [85, 35])
    }

    @Test func eachScannedResultCitesTheFactsItUsed() throws {
        let both = try Self.kandor(scanned: ScannedInvoice.all(from: Self.confirmed()))
        let scanned = both.filter { $0.subject == "Scanned invoice 14" }

        let names = scanned.map { result in
            result.inputs.compactMap { input -> String? in
                if case .fact(let ref) = input { return ref.name }
                return nil
            }
        }
        #expect(names == [["cumulativePaid", "contractValue"],
                          ["cumulativePaid", "contractValue", "kmCompleted", "kmTotal"]])
    }

    @Test func theScannedNumbersAreJudgedByTheSameThresholds() throws {
        let facts = InvoiceFacts(invoiceNumber: "15", invoiceDate: "2026-11-01", amountDue: 1,
                                 cumulativePaid: 10_500_000, contractValue: 10_000_000, kmCompleted: 16, kmTotal: 64,
                                 bridgeStatus: "in_progress")

        let scanned = try Self.kandor(scanned: ScannedInvoice.all(from: Self.confirmed(facts)))
            .filter { $0.subject == "Scanned invoice 15" }

        #expect(scanned.map(\.outcome) == [.flag, .flag])
        #expect(scanned.map(\.computed) == [105, 80])
    }

    @Test func aZeroContractValueOnTheScanIsNotChecked() throws {
        let facts = InvoiceChecksTests.facts(contractValue: 0)

        let scanned = try Self.kandor(scanned: ScannedInvoice.all(from: Self.confirmed(facts)))
            .filter { $0.subject == "Scanned invoice 14" }

        #expect(scanned.map(\.outcome) == [.notChecked(.zeroValue), .notChecked(.zeroValue)])
    }

    @Test func scannedResultsAreStoredAndReadBackWithTheirFacts() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: "kandor-roads", title: "Kandor rural roads")
        let flags = try Self.kandor(scanned: ScannedInvoice.all(from: Self.confirmed()))

        try store.finishWalk(form: SiteWalkStoreTests.form, version: "2026110401", mission: "kandor-roads",
                             flags: flags)

        #expect(try store.storedFlags(mission: "kandor-roads") == flags)
    }

    @Test func aScannedResultSaysItIsFromTheScanInItsSentence() throws {
        let scanned = try Self.kandor(scanned: ScannedInvoice.all(from: Self.confirmed()))
            .filter { $0.subject == "Scanned invoice 14" }

        #expect(scanned.map(RedFlagWordsTests.english.sentence) == [
            "Scanned invoice 14: paid 85% of the contract value.",
            "Scanned invoice 14: payments are 35 points ahead of the work built."
        ])
        #expect(RedFlagWordsTests.french.sentence(scanned[1])
                == "Facture scannée 14 : les paiements ont 35 points d'avance sur les travaux réalisés.")
    }

    @Test func aFactInputSaysItIsFromTheScan() {
        let input = RedFlagResult.Input.fact(FactRef(id: "f", name: "cumulativePaid"))

        #expect(RedFlagWordsTests.english.input(input, mission: "m") == "Scanned invoice · Paid to date")
        #expect(RedFlagWordsTests.french.input(input, mission: "m") == "Facture scannée · Payé à ce jour")
    }
}
