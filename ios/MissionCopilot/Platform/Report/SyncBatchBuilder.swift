import Foundation

/// What goes to the server (#173): the JSON body and the evidence files behind the cited facts.
struct SyncBatch: Sendable {
    struct Counts: Sendable, Equatable {
        let sentences: Int
        let facts: Int
        let evidence: Int
        let files: Int
        let bytes: Int
    }

    let body: Data
    let files: [Int]
    let counts: Counts
}

/// The batch the server's `SyncBatch` takes (#172, #173 step 8.3.1): the whole signed evidence chain and its
/// head (each link needs every item), only the facts the approved sentences cite, the approved draft's sentences,
/// and the Face ID approval exactly as signed. Bytes as base64, as the server reads them.
enum SyncBatchBuilder {
    struct NoApprovedReport: Error, Equatable {}

    private struct Item: Encodable { let payload: Data, signature: Data }
    private struct Source: Encodable { let seq: Int, region: String? }
    private struct SentFact: Encodable {
        let id: String, name: String, value: String, unit: String?, ruleId: String, ruleVersion: String
        let classification: String, sources: [Source]
    }
    private struct SentSentence: Encodable {
        let id: String, section: String, text: String, classification: String, factIds: [String]
    }
    private struct SentApproval: Encodable { let payload: Data, signature: Data, keyId: String }
    private struct Body: Encodable {
        let evidence: [Item], head: Item, facts: [SentFact], draftId: String, language: String
        let sentences: [SentSentence], approval: SentApproval
    }

    static func build(in mission: String, store: MissionStore) throws -> SyncBatch {
        guard let approval = try store.approval(in: mission),
              let draft = try store.drafts(in: mission).first(where: { $0.id == approval.draftId }),
              let head = try store.evidenceHead(in: mission) else { throw NoApprovedReport() }
        let chain = try store.evidence(in: mission)
        let cited = Set(draft.sentences.flatMap(\.factIds))
        let facts = try store.facts(in: mission).filter { cited.contains($0.id) }
        let files = Array(Set(facts.flatMap { $0.sources.map(\.seq) })).sorted()
        let body = Body(
            evidence: chain.map { Item(payload: $0.payload, signature: $0.signature) },
            head: Item(payload: head.payload, signature: head.signature),
            facts: facts.map { fact in
                SentFact(id: fact.id, name: fact.name, value: fact.value, unit: fact.unit, ruleId: fact.rule.id,
                         ruleVersion: fact.rule.version, classification: fact.classification.rawValue,
                         sources: fact.sources.map { Source(seq: $0.seq, region: $0.region) })
            },
            draftId: draft.id, language: draft.language,
            sentences: draft.sentences.map { sentence in
                SentSentence(id: sentence.id, section: sentence.section, text: sentence.text,
                             classification: sentence.classification.rawValue, factIds: sentence.factIds)
            },
            approval: SentApproval(payload: approval.payload, signature: approval.signature,
                                   keyId: ApprovalKeyRegistration.keyId(approval.publicKeyDER)))
        let data = try JSONEncoder().encode(body)
        return SyncBatch(body: data, files: files, counts: SyncBatch.Counts(
            sentences: draft.sentences.count, facts: facts.count, evidence: chain.count, files: files.count,
            bytes: data.count))
    }
}
