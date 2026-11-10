import Foundation
import Testing
@testable import MissionCopilot

/// Sending the approved report (#173, step 8.3.2): the approval key first (#171), the batch with its stable
/// Idempotency-Key, the receipt kept, then each file behind the cited facts once. With no signal it waits and
/// the next try is the same batch; a refusal says why; once received, nothing is sent again.
@MainActor
struct ReportSenderTests {
    static let mission = ReportModelTests.mission
    let service = "missioncopilot.tests.sender.\(UUID().uuidString)"
    let approvalSigner = FakeApprovalSigner()

    func sender(_ store: MissionStore) throws -> ReportSender {
        let records = DeviceRecordStore(service: service, user: "officer")
        try records.save(DeviceRecord(deviceId: "device-1", approved: true))
        return ReportSender(store: store, registration: ApprovalKeyRegistration(signer: approvalSigner,
                                                                                records: records))
    }

    func client(_ transport: FakeTransport) -> ServerClient {
        let counter = RequestCounter(items: KeychainItems(service: service + ".counter"), account: "device-1",
                                     now: { Date(timeIntervalSince1970: 1_793_000_000) })
        return ServerClient(base: URL(string: "https://kandor-works.example.org")!, deviceId: "device-1",
                            signer: SoftwareEvidenceSigner(), counter: counter, transport: transport,
                            now: { Date(timeIntervalSince1970: 1_793_000_123) })
    }

    /// One answer every route can read: the key id, a receipt, a file's confirmation.
    func server(_ status: Int = 201) throws -> FakeTransport {
        let key = ApprovalKeyRegistration.keyId(try approvalSigner.publicKeyDER())
        let body = #"{"keyId":"\#(key)","addedAt":"2026-11-10T00:00:00Z","batchId":"batch-1","#
            + #""receivedAt":"2026-11-10T01:00:00Z","itemCount":9,"alreadyApplied":false,"seq":1,"sha256":"x"}"#
        return FakeTransport(status: status, body: Data(body.utf8))
    }

    static func queued() async throws -> MissionStore {
        let store = try await ReportSendStoreTests.approved()
        try store.queueReport(in: mission)
        return store
    }

    @Test func theReportAndItsFilesGoOnceAndTheReceiptIsKept() async throws {
        let store = try await Self.queued()
        let transport = try server()
        let files = try SyncBatchBuilder.build(in: Self.mission, store: store).files

        let outcome = await try sender(store).send(mission: Self.mission, client: client(transport))

        #expect(outcome == .received(Date(timeIntervalSince1970: 1_794_272_400)))
        let paths = transport.sent.compactMap { $0.url?.path }
        #expect(paths.first == "/v1/devices/me/approval-key", "the key first")
        #expect(paths.dropFirst().first == "/v1/missions/\(Self.mission)/sync")
        #expect(Array(paths.dropFirst(2)) == files.map { "/v1/missions/\(Self.mission)/evidence/\($0)/file" })
        let sync = transport.sent[1]
        let key = try store.outbox(in: Self.mission)?.idempotencyKey
        #expect(sync.value(forHTTPHeaderField: "Idempotency-Key") == key)
        let file = try #require(transport.sent.last)
        #expect(file.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(file.httpBody == (try store.evidenceFile(in: Self.mission, seq: try #require(files.last))))
        #expect(try store.receipt(in: Self.mission)?.batchId == "batch-1")
        #expect(try store.filesSent(in: Self.mission) == files)

        let again = try server()
        #expect(await try sender(store).send(mission: Self.mission, client: client(again)) == outcome)
        #expect(again.sent.isEmpty, "received: nothing is sent again")
    }

    @Test func withNoSignalItWaitsAndTheNextTryIsTheSameBatch() async throws {
        let store = try await Self.queued()
        let offline = FakeTransport([.failure(URLError(.notConnectedToInternet))])

        #expect(await try sender(store).send(mission: Self.mission, client: client(offline)) == .waiting)
        #expect(try store.receipt(in: Self.mission) == nil)

        let online = try server()
        _ = await try sender(store).send(mission: Self.mission, client: client(online))
        let sync = try #require(online.sent.first { $0.url?.path.hasSuffix("/sync") == true })
        let key = try store.outbox(in: Self.mission)?.idempotencyKey
        #expect(sync.value(forHTTPHeaderField: "Idempotency-Key") == key)
    }

    @Test func aRefusalSaysWhyAndKeepsNoReceipt() async throws {
        let store = try await Self.queued()
        let key = ApprovalKeyRegistration.keyId(try approvalSigner.publicKeyDER())
        let transport = FakeTransport([
            .success(.init(status: 201, body: Data(#"{"keyId":"\#(key)","addedAt":"2026-11-10T00:00:00Z"}"#.utf8))),
            .success(.init(status: 422))
        ])

        let outcome = await try sender(store).send(mission: Self.mission, client: client(transport))

        #expect(outcome == .refused(ReportSender.refusedWords))
        #expect(try store.receipt(in: Self.mission) == nil)
    }

    @Test func aReportNotQueuedSendsNothing() async throws {
        let store = try await ReportSendStoreTests.approved()
        let transport = try server()

        #expect(await try sender(store).send(mission: Self.mission, client: client(transport)) == .notQueued)
        #expect(transport.sent.isEmpty)
    }
}
