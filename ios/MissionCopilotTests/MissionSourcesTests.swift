import Foundation
import Testing
@testable import MissionCopilot

/// The mission's sources (#145, step 6.7.1): every piece of mission data on the phone as a short text with an
/// id, a kind, a title in words and where it came from, so a question can find it and an answer can cite it.
/// Built in memory; only signed pack files and confirmed records are sources.
struct MissionSourcesTests {
    static var pack: [String: Data] { PackSectionsTests.files }

    static func sources(_ inputs: SourceInputs = SourceInputs(packFiles: pack)) -> [MissionSource] {
        MissionSources.build(inputs)
    }

    @Test func eachPackObjectIsASourceThatCitesItsField() throws {
        let sources = Self.sources()
        let contracts = try #require(Self.pack[PackContracts.path])

        let payment = try #require(sources.first { $0.text.contains("reference: Invoice 14") })
        #expect(payment.kind == .pack)
        #expect(payment.title == "Contracts › contracts 1 › payments 6")
        #expect(payment.text == "amount: 480000\ndate: 2026-10-12\nreference: Invoice 14")
        guard case .pack(let citation) = payment.origin else {
            Issue.record("not a pack source")
            return
        }
        #expect(citation.pointer == "/contracts/0/payments/5")
        #expect(try citation.value(in: contracts)
                == .object(["amount": .number(480_000), "date": .string("2026-10-12"),
                            "reference": .string("Invoice 14")]))
        let contract = try #require(sources.first { $0.id == "pack:sections/contracts.json#/contracts/0" })
        #expect(contract.text.contains("contract value: 10000000"))
    }

    /// Code adds the payments up (ADR 0005: the model never does arithmetic): "How much was paid?" has a source.
    @Test func paidToDateIsAddedUpByCodeAndCitesThePayments() throws {
        let id = "pack:sections/contracts.json#/contracts/0/payments#paid"
        let paid = try #require(Self.sources().first { $0.id == id })

        #expect(paid.title == "Contracts › contracts 1 › paid to date")
        #expect(paid.text == "paid to date: 8500000 (the sum of the pack's 6 payments, added by the app)")
        guard case .pack(let citation) = paid.origin else {
            Issue.record("not a pack source")
            return
        }
        #expect(citation.pointer == "/contracts/0/payments")
    }

    @Test func eachDocumentParagraphIsASource() throws {
        let sources = Self.sources()

        let summary = try #require(sources.first { $0.text.hasPrefix("Previous mission (May 2026)") })
        #expect(summary.kind == .document)
        #expect(summary.title == "Aide-memoire: Supervision mission, May 2026 · paragraph 3")
        #expect(summary.origin == .document(path: "documents/aide-memoire-2026-05.md", paragraph: 3))
        #expect(sources.contains { $0.kind == .document && $0.text.contains("Section 3 bridge: not started") })
    }

    @Test func confirmedFactsAndNotesAreSourcesInWords() throws {
        let scan = Fact(id: "f1", name: "amountDue", value: "480000", unit: "USD", rule: MissionStore.scanRule,
                        classification: .officialUseOnly, sources: [FactSource(seq: 3, region: nil)])
        let note = Fact(id: "f2", name: "debrief.action",
                        value: #"{"byWhen":"in two weeks","text":"Contractor sends a new work plan.","#
                            + #""who":"contractor"}"#,
                        unit: nil, rule: MissionStore.debriefRule, classification: .officialUseOnly,
                        sources: [FactSource(seq: 5, region: "apple-speechtranscriber-1 text 10+20")])
        let heard = Fact(id: "f3", name: "spoken.amount", value: "480000", unit: "dollars",
                         rule: MissionStore.debriefRule, classification: .officialUseOnly,
                         sources: [FactSource(seq: 5, region: nil)])

        let sources = Self.sources(SourceInputs(facts: [scan, note, heard]))

        #expect(sources.map(\.id) == ["fact:f1", "fact:f2", "fact:f3"])
        #expect(sources.map(\.title) == ["Scanned invoice · Amount due", "Debrief note · Action",
                                         "Heard in a debrief · Amount"])
        #expect(sources.map(\.text) == ["Amount due: 480000 USD",
                                        "Contractor sends a new work plan. Who: contractor. By when: in two weeks.",
                                        "480000 dollars"])
        #expect(sources[1].origin == .fact(id: "f2", sources: note.sources))
        #expect(sources.allSatisfy { $0.kind == .fact || $0.kind == .note })
        #expect(sources[1].kind == .note)
    }

    @Test func walkAnswersAndRedFlagsComeInWords() {
        let inputs = SourceInputs(
            walk: [WordedLine(key: "bridge_started", title: "Has work on the Section 3 bridge started?", text: "No")],
            flags: [WordedLine(key: "MC-01", title: "Payments ahead of physical progress",
                               text: "Payments are 35 points ahead of the work built."),
                    WordedLine(key: "MC-01", title: "Payments ahead of physical progress",
                               text: "Scanned invoice 14: payments are 35 points ahead of the work built.")])

        let sources = Self.sources(inputs)

        // Two results of one rule (the pack's and a scanned invoice's) keep apart.
        #expect(sources.map(\.id) == ["walk:bridge_started", "flag:MC-01:0", "flag:MC-01:1"])
        #expect(sources.map(\.kind) == [.walkAnswer, .redFlag, .redFlag])
        #expect(sources[0].text == "Has work on the Section 3 bridge started? No")
        #expect(sources[1].origin == .redFlag(rule: "MC-01"))
    }

    @Test func idsAreUniqueAndTheSameEveryTime() {
        let first = Self.sources(), again = Self.sources()

        #expect(Set(first.map(\.id)).count == first.count)
        #expect(first.map(\.id) == again.map(\.id))
        #expect(first.count > 40)  // every section and paragraph of the Kandor pack
    }

    @Test func aDisclaimerOrAHeadingAloneIsNotASource() {
        let sources = Self.sources()

        #expect(!sources.contains { $0.text.hasPrefix("Fictional:") })
        #expect(!sources.contains { $0.text.hasPrefix("#") && !$0.text.contains("\n") })
        #expect(!sources.contains { $0.text.isEmpty })
    }

    /// The loader on a real imported Kandor pack, a confirmed fact and a walk answer.
    @Test @MainActor func everythingOnThePhoneIsLoadedFromTheStore() async throws {
        let rig = try PackDownloaderTests.Rig()
        guard case .verified(let ready) = await rig.run() else { throw CancellationError() }
        let store = try MissionStore(store: EncryptedStore.open(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite"),
            key: DataKey.random()), vault: SoftwareKeyVault())
        let mission = PackDownloaderTests.mission
        _ = try PackImport.run(ready, title: "Kandor Rural Roads Project, Package 1", into: store,
                               schema: PackSectionsTests.schema())
        try store.saveAnswer("no", to: "bridge_started", form: SiteWalkStoreTests.form, mission: mission)
        let scan = try store.addScan([try ScanStoreTests.page()], to: mission, signer: SoftwareEvidenceSigner())
        try store.addFacts([FactInput(name: "amountDue", value: "480000", unit: "USD",
                                      sources: [FactSource(seq: scan.pages[0], region: nil)],
                                      rule: MissionStore.scanRule)], to: mission)

        let sources = MissionSources.load(mission: mission, store: store)

        #expect(sources.contains { $0.kind == .document && $0.text.hasPrefix("Previous mission") })
        #expect(sources.contains { $0.text == "Amount due: 480000 USD" })
        #expect(sources.contains { $0.id == "walk:bridge_started" && $0.text.hasSuffix(" no") })
        #expect(sources.contains { $0.kind == .redFlag })
        #expect(MissionSources.load(mission: "no-such-mission", store: store).isEmpty)
    }
}
