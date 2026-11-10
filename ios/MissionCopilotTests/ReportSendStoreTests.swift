import Foundation
import GRDB
import Testing
@testable import MissionCopilot

/// What the phone sends after the approval (#173, step 8.3.1): only an approved report goes in the outbox
/// (threat T28), with a stable Idempotency-Key; the batch is the exact JSON the server's SyncBatch takes (#172):
/// the whole signed chain, only the cited facts, the approved sentences, and the Face ID approval unchanged.
@MainActor
struct ReportSendStoreTests {
    static let mission = ReportModelTests.mission

    static func approved() async throws -> MissionStore {
        let ready = try await ReportModelApprovalTests.ready()
        await ready.model.approve()
        #expect(ready.model.state == .approved)
        return ready.store
    }

    @Test func onlyAnApprovedReportIsQueued() async throws {
        let (store, _) = try await ReportSourcesTests.finished()

        #expect(throws: MissionStore.NotApproved()) { try store.queueReport(in: Self.mission) }
        #expect(try store.outbox(in: Self.mission) == nil)
    }

    @Test func theQueuedReportKeepsOneStableKey() async throws {
        let store = try await Self.approved()

        let first = try store.queueReport(in: Self.mission)
        let again = try store.queueReport(in: Self.mission)

        #expect(first == again, "queued once: the same key every try")
        #expect(UUID(uuidString: first.idempotencyKey) != nil)
        #expect(first.draftId == (try store.approval(in: Self.mission))?.draftId)
    }

    @Test func aReceiptAndTheFilesSentAreKept() async throws {
        let store = try await Self.approved()
        try store.queueReport(in: Self.mission)
        let when = Date(timeIntervalSince1970: 1_794_270_000)

        try store.keepReceipt(batchId: "batch-1", receivedAt: when, in: Self.mission)
        try store.keepFileSent(seq: 2, in: Self.mission)
        try store.keepFileSent(seq: 2, in: Self.mission)

        #expect(try store.receipt(in: Self.mission) == ReportReceipt(batchId: "batch-1", receivedAt: when))
        #expect(try store.filesSent(in: Self.mission) == [2])
        for sql in ["UPDATE report_outbox SET draft_id = 'x'", "DELETE FROM report_receipt"] {
            #expect(throws: (any Error).self, "\(sql)") { try store.store.write { try $0.execute(sql: sql) } }
        }
    }

    @Test func theBatchIsWhatTheServerTakes() async throws {
        let store = try await Self.approved()
        let approval = try #require(try store.approval(in: Self.mission))

        let batch = try SyncBatchBuilder.build(in: Self.mission, store: store)
        let json = try #require(try JSONSerialization.jsonObject(with: batch.body) as? [String: Any])

        #expect(Set(json.keys) == ["evidence", "head", "facts", "draftId", "language", "sentences", "approval"])
        let evidence = try #require(json["evidence"] as? [[String: String]])
        #expect(evidence.count == (try store.evidence(in: Self.mission)).count, "the whole chain")
        #expect(evidence.first.map { Set($0.keys) } == ["payload", "signature"])
        let sentences = try #require(json["sentences"] as? [[String: Any]])
        let cited = Set(sentences.flatMap { ($0["factIds"] as? [String]) ?? [] })
        let facts = try #require(json["facts"] as? [[String: Any]])
        #expect(Set(facts.compactMap { $0["id"] as? String }) == cited, "only the cited facts")
        let sent = try #require(json["approval"] as? [String: String])
        #expect(sent["payload"] == approval.payload.base64EncodedString(), "the signed bytes unchanged")
        #expect(sent["keyId"] == ApprovalKeyRegistration.keyId(approval.publicKeyDER))
        #expect(json["draftId"] as? String == approval.draftId)
        let seqs = Set(facts.flatMap { (($0["sources"] as? [[String: Any]]) ?? []).compactMap { $0["seq"] as? Int } })
        #expect(Set(batch.files) == seqs, "the files behind the cited facts")
        #expect(batch.counts.sentences == sentences.count && batch.counts.facts == facts.count)
    }

    /// The server checks the approval against these sentences: the batch's must be the signed ones.
    @Test func theBatchSentencesAreTheSignedOnes() async throws {
        let store = try await Self.approved()
        let approval = try #require(try store.approval(in: Self.mission))

        let json = try JSONSerialization.jsonObject(with: try SyncBatchBuilder.build(in: Self.mission, store: store)
            .body) as? [String: Any]
        let signed = try JSONSerialization.jsonObject(with: approval.payload) as? [String: Any]

        let lines = { (items: Any?) in
            ((items as? [[String: Any]]) ?? []).map { line in
                "\(line["section"] ?? "")|\(line["text"] ?? "")|\(line["factIds"] ?? "")"
            }
        }
        #expect(lines(json?["sentences"]) == lines(signed?["sentences"]))
    }
}
