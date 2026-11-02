import Foundation
import Testing
@testable import MissionCopilot

/// Facts with their lineage (ADR 0009, W3C PROV, #72): every fact names the evidence it came from and
/// the rule version that produced it, inherits the strictest label of its sources, and keeps its value
/// sealed with the mission key. The database itself refuses a fact with no source.
struct FactStoreTests {
    private let signer = SoftwareEvidenceSigner()

    private func mission(evidence labels: [Classification] = [.officialUseOnly]) throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let encrypted = try EncryptedStore.open(at: file, key: DataKey.random())
        let store = MissionStore(store: encrypted, vault: SoftwareKeyVault())
        try store.create(mission: "kandor-roads", title: "Kandor rural roads")
        for (index, label) in labels.enumerated() {
            try store.addEvidence(EvidenceChainTests.capture("page-\(index)", minute: index, kind: .scan),
                                  to: "kandor-roads", signer: signer, classification: label)
        }
        return store
    }

    static let mc01 = RuleRef(id: "MC-01", version: "1")

    private func amount(_ sources: [FactSource] = [FactSource(seq: 1, region: "line 7")]) -> FactInput {
        FactInput(name: "amountDue", value: "480000", unit: "USD", sources: sources, rule: Self.mc01)
    }

    @Test func aFactReadsBackWithItsSourceRuleAndLabel() throws {
        let store = try mission()

        let added = try store.addFact(amount(), to: "kandor-roads")

        let fact = try #require(try store.facts(in: "kandor-roads").first)
        #expect(fact == added)
        #expect((fact.name, fact.value, fact.unit) == ("amountDue", "480000", "USD"))
        #expect(fact.sources == [FactSource(seq: 1, region: "line 7")])
        #expect(fact.rule == Self.mc01)
        #expect(fact.classification == .officialUseOnly)
    }

    @Test func aFactInheritsTheStrictestLabelOfItsSources() throws {
        let store = try mission(evidence: [.public, .strictlyConfidential])

        let fact = try store.addFact(amount([FactSource(seq: 1, region: nil), FactSource(seq: 2, region: nil)]),
                                     to: "kandor-roads")

        #expect(fact.classification == .strictlyConfidential)
        // Read back from the database, not the value addFact returned: sources in evidence order.
        let stored = try #require(try store.facts(in: "kandor-roads").first)
        #expect(stored.sources.map(\.seq) == [1, 2] && stored.classification == .strictlyConfidential)
    }

    @Test func aFactWithNoSourceIsRefused() throws {
        #expect(throws: FactError.noSource) { try mission().addFact(amount([]), to: "kandor-roads") }
    }

    @Test func aSourceThatIsNotEvidenceOfThisMissionIsRefused() throws {
        let store = try mission()

        #expect(throws: FactError.unknownSource(seq: 9)) {
            try store.addFact(amount([FactSource(seq: 9, region: nil)]), to: "kandor-roads")
        }
        #expect(try store.facts(in: "kandor-roads").isEmpty)
    }

    @Test func theDatabaseItselfRefusesAFactWithNoSource() throws {
        // Defense in depth: even a buggy caller that skips the code check cannot store such a fact.
        let store = try mission()

        #expect(throws: (any Error).self) {
            try store.store.rawExecuteForTests("""
                INSERT INTO fact (id, mission_id, name, sealed_value, rule_id, rule_version, classification,
                                  created_at, first_source_seq)
                VALUES ('f1', 'kandor-roads', 'amountDue', x'00', 'MC-01', '1', 'official_use_only', 0, NULL)
                """)
        }
    }

    @Test func theValueIsSealedInTheDatabase() throws {
        let store = try mission()
        try store.addFact(amount(), to: "kandor-roads")

        let sealed = try store.sealedFactValues(in: "kandor-roads")
        #expect(sealed.count == 1 && sealed[0].range(of: Data("480000".utf8)) == nil)
    }

    @Test func aShreddedMissionsFactsCannotBeReadAndPurgeRemovesThem() throws {
        let store = try mission()
        try store.addFact(amount(), to: "kandor-roads")

        try store.shred(mission: "kandor-roads")
        #expect(throws: MissionKeyNotFound(mission: "kandor-roads")) { try store.facts(in: "kandor-roads") }

        try store.purge(mission: "kandor-roads")
        #expect(try store.sealedFactValues(in: "kandor-roads").isEmpty)
    }
}
