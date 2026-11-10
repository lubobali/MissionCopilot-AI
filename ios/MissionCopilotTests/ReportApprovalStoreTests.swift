import CryptoKit
import Foundation
import GRDB
import Testing
@testable import MissionCopilot

/// The approval record (#163, step 7.3.3): the signed approval of the latest saved draft, stored once (v21),
/// append-only, with an audit entry; after it the report cannot be edited or drafted over.
@MainActor
struct ReportApprovalStoreTests {
    static let mission = PackDownloaderTests.mission
    static let when = Date(timeIntervalSince1970: 1_794_268_800)

    static func saved() async throws -> (MissionStore, ReportDraft) {
        let (store, lines) = try await ReportDraftStoreTests.drafted()
        return (store, try store.saveDraft(lines, language: .english, in: mission))
    }

    static func signed(_ draft: ReportDraft, by user: String = "this-phone") async throws -> SignedApproval {
        try await ReportApproval.sign(draft: draft, mission: mission, by: user, at: when, signer: FakeApprovalSigner())
    }

    @Test func theApprovalIsStoredWithItsSignature() async throws {
        let (store, draft) = try await Self.saved()
        let signed = try await Self.signed(draft)

        let record = try store.approve(signed, draft: draft, by: "this-phone", at: Self.when, in: Self.mission)

        #expect(try store.approval(in: Self.mission) == record)
        #expect(record.draftId == draft.id && record.approvedBy == "this-phone" && record.approvedAt == Self.when)
        let key = try P256.Signing.PublicKey(derRepresentation: record.publicKeyDER)
        #expect(key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: record.signature),
                                     for: record.payload))
    }

    /// Only the latest saved draft, and only the bytes of that draft: a signature over anything else is refused.
    @Test func onlyTheLatestDraftAsSigned() async throws {
        let (store, first) = try await Self.saved()
        let second = try store.saveDraft(ReportDraftStoreTests.lines(first).dropLast(), language: .english,
                                         in: Self.mission)

        let old = try await Self.signed(first)
        #expect(throws: MissionStore.NotTheLatestDraft()) {
            try store.approve(old, draft: first, by: "this-phone", at: Self.when, in: Self.mission)
        }
        let other = try await Self.signed(first)
        #expect(throws: MissionStore.NotWhatWasSigned()) {
            try store.approve(other, draft: second, by: "this-phone", at: Self.when, in: Self.mission)
        }
        let stranger = try await Self.signed(second, by: "someone-else")
        #expect(throws: MissionStore.NotWhatWasSigned()) {
            try store.approve(stranger, draft: second, by: "this-phone", at: Self.when, in: Self.mission)
        }
        #expect(try store.approval(in: Self.mission) == nil)
    }

    /// Approved once: no second approval, no new draft over it.
    @Test func afterTheApprovalNothingChanges() async throws {
        let (store, draft) = try await Self.saved()
        try store.approve(try await Self.signed(draft), draft: draft, by: "this-phone", at: Self.when,
                          in: Self.mission)

        let again = try await Self.signed(draft)
        #expect(throws: MissionStore.ReportApproved()) {
            try store.approve(again, draft: draft, by: "this-phone", at: Self.when, in: Self.mission)
        }
        #expect(throws: MissionStore.ReportApproved()) {
            try store.saveDraft(ReportDraftStoreTests.lines(draft), language: .english, in: Self.mission)
        }
        for sql in ["UPDATE report_approval SET approved_by = 'x'", "DELETE FROM report_approval"] {
            #expect(throws: (any Error).self, "\(sql)") { try store.store.write { try $0.execute(sql: sql) } }
        }
    }

    @Test func theAuditNamesTheDraftNeverItsWords() async throws {
        let (store, draft) = try await Self.saved()

        try store.approve(try await Self.signed(draft), draft: draft, by: "this-phone", at: Self.when,
                          in: Self.mission)

        let events = try store.store.auditEvents()
        let approved = events.filter { $0.action == .reportApproved }
        #expect(approved.map(\.target) == [draft.id])
    }
}
