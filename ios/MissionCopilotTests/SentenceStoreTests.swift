import Foundation
import Testing
@testable import MissionCopilot

/// Report sentences with their lineage (ADR 0009, #72): a sentence needs at least one fact of its own
/// mission, inherits the strictest label of its facts, and any reader can follow it back to the facts
/// and the evidence they came from. The database itself refuses a sentence with no fact.
struct SentenceStoreTests {
    /// A mission with two pieces of evidence (labels given) and one fact on each.
    static func mission(_ labels: [Classification] = [.officialUseOnly, .officialUseOnly],
                        id: String = "kandor-roads",
                        in existing: MissionStore? = nil) throws -> (MissionStore, [Fact]) {
        let store = try existing ?? {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
            let encrypted = try EncryptedStore.open(at: file, key: DataKey.random())
            return MissionStore(store: encrypted, vault: SoftwareKeyVault())
        }()
        try store.create(mission: id, title: id)
        var facts: [Fact] = []
        for (index, label) in labels.enumerated() {
            try store.addEvidence(EvidenceChainTests.capture("page-\(index)", minute: index, kind: .scan), to: id,
                                  signer: SoftwareEvidenceSigner(), classification: label)
            facts.append(try store.addFact(FactInput(name: "fact-\(index)", value: "\(index)", unit: nil,
                                                     sources: [FactSource(seq: index + 1, region: nil)],
                                                     rule: FactStoreTests.mc01), to: id))
        }
        return (store, facts)
    }

    private func sentence(_ facts: [Fact]) -> SentenceInput {
        SentenceInput(section: "Findings", text: "Payments run 35 points ahead of the road built.",
                      factIds: facts.map(\.id))
    }

    @Test func aSentenceReadsBackWithItsFacts() throws {
        let (store, facts) = try Self.mission()

        let added = try store.addSentence(sentence(facts), to: "kandor-roads")

        #expect(try store.sentences(in: "kandor-roads") == [added])
        #expect(added.factIds == facts.map(\.id) && added.section == "Findings")
    }

    @Test func theFactsComeBackInTheOrderTheSentenceUsesThem() throws {
        let (store, facts) = try Self.mission(Array(repeating: .officialUseOnly, count: 5))
        let order = [facts[3], facts[0], facts[4], facts[1], facts[2]]

        try store.addSentence(sentence(order), to: "kandor-roads")

        #expect(try store.sentences(in: "kandor-roads").first?.factIds == order.map(\.id))
    }

    @Test func aSentenceInheritsTheStrictestLabelOfItsFacts() throws {
        let (store, facts) = try Self.mission([.public, .strictlyConfidential])

        #expect(try store.addSentence(sentence(facts), to: "kandor-roads").classification == .strictlyConfidential)
        #expect(try store.sentences(in: "kandor-roads").first?.classification == .strictlyConfidential)
    }

    @Test func aSentenceWithNoFactIsRefused() throws {
        #expect(throws: SentenceError.noFact) { try Self.mission().0.addSentence(sentence([]), to: "kandor-roads") }
    }

    @Test func aFactOfAnotherMissionIsRefused() throws {
        let (store, _) = try Self.mission()
        let (_, otherFacts) = try Self.mission(id: "kandor-bridges", in: store)

        #expect(throws: SentenceError.unknownFact(id: otherFacts[0].id)) {
            try store.addSentence(sentence(otherFacts), to: "kandor-roads")
        }
    }

    @Test func theDatabaseItselfRefusesASentenceWithNoFactOrAnotherMissionsFact() throws {
        let (store, _) = try Self.mission()
        let (_, otherFacts) = try Self.mission(id: "kandor-bridges", in: store)
        let insert = """
            INSERT INTO sentence (id, mission_id, section, sealed_text, classification, created_at, first_fact_id)
            VALUES ('s1', 'kandor-roads', 'Findings', x'00', 'official_use_only', 0, %@)
            """

        #expect(throws: (any Error).self) {
            try store.store.rawExecuteForTests(insert.replacingOccurrences(of: "%@", with: "NULL"))
        }
        #expect(throws: (any Error).self) {
            try store.store.rawExecuteForTests(insert.replacingOccurrences(of: "%@", with: "'\(otherFacts[0].id)'"))
        }
    }

    @Test func traceFollowsASentenceBackToItsFactsAndEvidence() throws {
        let (store, facts) = try Self.mission()
        let added = try store.addSentence(sentence(facts), to: "kandor-roads")

        let trace = try store.trace(sentence: added.id, in: "kandor-roads")

        #expect(trace.sentence == added)
        #expect(trace.facts.map(\.id) == facts.map(\.id))
        #expect(trace.evidence.map(\.seq) == [1, 2])
        let firstEvidence = try #require(trace.evidence.first)  // fail cleanly, never crash on an empty list
        let first = try JSONDecoder().decode(EvidencePayload.self, from: firstEvidence.record.payload)
        #expect((first.kind, first.seq) == (.scan, 1))
    }

    @Test func theTextIsSealedAndAShredMakesItUnreadable() throws {
        let (store, facts) = try Self.mission()
        try store.addSentence(sentence(facts), to: "kandor-roads")
        let sealed = try store.sealedSentenceTexts(in: "kandor-roads")
        #expect(sealed.count == 1 && sealed[0].range(of: Data("Payments".utf8)) == nil)

        try store.shred(mission: "kandor-roads")
        #expect(throws: MissionKeyNotFound(mission: "kandor-roads")) { try store.sentences(in: "kandor-roads") }

        try store.purge(mission: "kandor-roads")
        #expect(try store.sealedSentenceTexts(in: "kandor-roads").isEmpty)
    }
}
