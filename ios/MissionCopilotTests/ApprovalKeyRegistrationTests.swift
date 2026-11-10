import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// The phone tells the server its Face ID approval key (#171, step 8.1.2): once, by itself, only when approved;
/// nothing kept when it could not be sent, so the next try sends again.
struct ApprovalKeyRegistrationTests {
    let service = "missioncopilot.tests.approvalkey.\(UUID().uuidString)"
    let signer = FakeApprovalSigner()

    func records(approved: Bool = true, keyId: String? = nil) throws -> DeviceRecordStore {
        let store = DeviceRecordStore(service: service, user: "officer")
        try store.save(DeviceRecord(deviceId: "device-1", approved: approved, approvalKeyId: keyId))
        return store
    }

    func client(_ transport: FakeTransport) -> ServerClient {
        let counter = RequestCounter(items: KeychainItems(service: service + ".counter"), account: "device-1",
                                     now: { Date(timeIntervalSince1970: 1_793_000_000) })
        return ServerClient(base: URL(string: "https://kandor-works.example.org")!, deviceId: "device-1",
                            signer: SoftwareEvidenceSigner(), counter: counter, transport: transport,
                            now: { Date(timeIntervalSince1970: 1_793_000_123) })
    }

    func answer(_ status: Int, keyId: String) -> FakeTransport {
        FakeTransport(status: status, body: Data(#"{"keyId":"\#(keyId)","addedAt":"2026-11-10T00:00:00Z"}"#.utf8))
    }

    var keyId: String { ApprovalKeyRegistration.keyId((try? signer.publicKeyDER()) ?? Data()) }

    @Test func theKeyIsSentOnceAndRemembered() async throws {
        let records = try records()
        let transport = answer(201, keyId: keyId)
        let registration = ApprovalKeyRegistration(signer: signer, records: records)

        #expect(await registration.ensure(client: client(transport)) == .registered)
        #expect(await registration.ensure(client: client(transport)) == .alreadyKnown)

        #expect(transport.sent.count == 1, "the second time sends nothing")
        let request = try #require(transport.sent.first)
        #expect(request.url?.path == "/v1/devices/me/approval-key" && request.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["publicKeyDER": try signer.publicKeyDER().base64EncodedString()])
        #expect(records.load()?.approvalKeyId == keyId)
        #expect(signer.signatures == 0, "reading the public key asks no Face ID")
    }

    @Test func alreadyKeptOnTheServerIsFineToo() async throws {
        let records = try records()

        let result = await ApprovalKeyRegistration(signer: signer, records: records)
            .ensure(client: client(answer(200, keyId: keyId)))

        #expect(result == .registered && records.load()?.approvalKeyId == keyId)
    }

    @Test func offlineOrRefusedKeepsNothingSoItTriesAgain() async throws {
        for transport in [FakeTransport([.failure(URLError(.notConnectedToInternet))]), FakeTransport(status: 401),
                          FakeTransport(status: 503), answer(201, keyId: String(repeating: "0", count: 64))] {
            let records = try records()

            let registration = ApprovalKeyRegistration(signer: signer, records: records)
            let result = await registration.ensure(client: client(transport))

            #expect(result == .notYet, "\(transport.sent.count)")
            #expect(records.load()?.approvalKeyId == nil)
        }
    }

    @Test func aPhoneNotApprovedSendsNothing() async throws {
        let transport = answer(201, keyId: keyId)

        let result = await ApprovalKeyRegistration(signer: signer, records: try records(approved: false))
            .ensure(client: client(transport))

        #expect(result == .notYet && transport.sent.isEmpty)
    }

    /// A new approval key (a phone set up again) is sent again; the old key id is replaced.
    @Test func aNewKeyIsSentEvenIfAnOldOneWasKnown() async throws {
        let records = try records(keyId: String(repeating: "a", count: 64))
        let transport = answer(201, keyId: keyId)

        #expect(await ApprovalKeyRegistration(signer: signer, records: records).ensure(client: client(transport))
                == .registered)
        #expect(transport.sent.count == 1 && records.load()?.approvalKeyId == keyId)
    }

    /// A record kept by an older build (no key id) still opens.
    @Test func anOlderRecordStillOpens() throws {
        let old = Data(#"{"deviceId":"device-1","approved":true}"#.utf8)
        let record = try JSONDecoder().decode(DeviceRecord.self, from: old)
        #expect(record.approvalKeyId == nil && record.approved)
    }
}
