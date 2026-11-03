import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// A shred order on the phone (ADR 0012, #60, threat T18). The server answers a revoked phone's signed
/// request with a 410 and an order signed by its key. The phone checks it before anything else: a real
/// order, signed by a pinned key over the exact bytes, naming this phone, issued just now. Only then is
/// every mission destroyed and recorded; any other order changes nothing.
struct ShredOrderTests {
    struct Fixture: Decodable { let deviceId: String; let issuedAt: Int; let serverPublicKeyDER: Data; let body: Data }

    static let fixture: Fixture = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/api/fixtures/shred-order.json")
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    static var serverKey: P256.Signing.PublicKey {
        // swiftlint:disable:next force_try
        try! P256.Signing.PublicKey(derRepresentation: fixture.serverPublicKeyDER)
    }

    static func at(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

    private func check(_ body: Data = fixture.body, device: String = fixture.deviceId,
                       keys: [P256.Signing.PublicKey] = [serverKey], now: Int = fixture.issuedAt + 3)
        -> ShredOrderCheck.Verdict {
        ShredOrderCheck.check(body, deviceId: device, keys: keys, now: Self.at(now))
    }

    /// The fixture's order with its fields changed and signed again by `key`.
    private func forged(deviceId: String? = nil, scope: String = "all-missions", issuedAt: Int? = nil,
                        type: String = ShredOrderCheck.problemType, key: P256.Signing.PrivateKey) throws -> Data {
        let device = deviceId ?? Self.fixture.deviceId, time = issuedAt ?? Self.fixture.issuedAt
        let message = ShredOrderCheck.message(deviceId: device, scope: scope, issuedAt: time)
        let order: [String: Any] = ["deviceId": device, "scope": scope, "issuedAt": time]
        let body: [String: Any] = ["type": type, "status": 410, "order": order,
                                   "signature": try key.signature(for: message).derRepresentation.base64EncodedString()]
        return try JSONSerialization.data(withJSONObject: body)
    }

    @Test(.needsRepoFiles) func theServersRealOrderForThisPhoneIsAccepted() {
        #expect(check() == .valid(issuedAt: Self.fixture.issuedAt))
    }

    @Test(.needsRepoFiles) func theMessageIsTheServersBytes() throws {
        let body = try JSONSerialization.jsonObject(with: Self.fixture.body) as? [String: Any]
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: try #require(Data(base64Encoded: body?["signature"] as? String ?? "")))
        let message = ShredOrderCheck.message(deviceId: Self.fixture.deviceId, scope: "all-missions",
                                              issuedAt: Self.fixture.issuedAt)

        #expect(Self.serverKey.isValidSignature(signature, for: message))
    }

    @Test(.needsRepoFiles) func anOrderSignedByAKeyThatIsNotPinnedIsRefused() {
        #expect(check(keys: [P256.Signing.PrivateKey().publicKey]) == .refused(.badSignature))
    }

    @Test(.needsRepoFiles) func oneOfSeveralPinnedKeysIsEnough() {
        let keys = [P256.Signing.PrivateKey().publicKey, Self.serverKey]

        #expect(check(keys: keys) == .valid(issuedAt: Self.fixture.issuedAt))
    }

    @Test(.needsRepoFiles) func anotherPhonesOrderIsRefusedEvenWhenGenuine() {
        #expect(check(device: "6f1d2c3a-1111-4000-8000-000000000009") == .refused(.otherPhone))
    }

    @Test(.needsRepoFiles, arguments: [-301, 301, 86_400])
    func anOrderFromAnotherTimeIsRefused(offset: Int) {
        #expect(check(now: Self.fixture.issuedAt + offset) == .refused(.notRecent))
    }

    @Test(.needsRepoFiles) func anOrderWithAChangedFieldNoLongerMatchesItsSignature() throws {
        var body = try #require(try JSONSerialization.jsonObject(with: Self.fixture.body) as? [String: Any])
        var order = try #require(body["order"] as? [String: Any])
        order["issuedAt"] = Self.fixture.issuedAt + 1
        body["order"] = order

        #expect(check(try JSONSerialization.data(withJSONObject: body)) == .refused(.badSignature))
    }

    @Test func aSignedOrderOfAnotherProblemTypeIsNotAShredOrder() throws {
        let key = P256.Signing.PrivateKey()
        let body = try forged(type: "about:blank", key: key)

        #expect(ShredOrderCheck.check(body, deviceId: Self.fixture.deviceId, keys: [key.publicKey],
                                      now: Self.at(Self.fixture.issuedAt)) == .refused(.notAnOrder))
    }

    @Test func anOrderForOnlySomeMissionsIsNotThisKindOfOrder() throws {
        let key = P256.Signing.PrivateKey()
        let body = try forged(scope: "one-mission", key: key)

        #expect(ShredOrderCheck.check(body, deviceId: Self.fixture.deviceId, keys: [key.publicKey],
                                      now: Self.at(Self.fixture.issuedAt)) == .refused(.notAnOrder))
    }

    @Test(arguments: [Data(), Data("not json".utf8), Data(#"{"type":"about:blank","status":410}"#.utf8),
                      Data(#"{"type":"urn:missioncopilot:problem:shred-order","order":{},"signature":"x"}"#.utf8)])
    func somethingThatIsNotAShredOrderIsRefused(body: Data) {
        #expect(ShredOrderCheck.check(body, deviceId: "d", keys: [Self.serverKey], now: Self.at(0))
                == .refused(.notAnOrder))
    }
}

/// Acting on a shred order (#60): only a checked order destroys anything; then every mission is gone,
/// each recorded with the reason, and the phone forgets its enrollment (it was revoked).
@Suite(.serialized) struct ShredOrderActionTests {
    let service = "missioncopilot.tests.shred.\(UUID().uuidString)"

    private func missions(_ names: [String]) throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let encrypted = try EncryptedStore.open(at: file, key: DataKey.random())
        let store = MissionStore(store: encrypted, vault: SoftwareKeyVault())
        for name in names {
            try store.create(mission: name, title: name, now: ShredOrderTests.at(ShredOrderTests.fixture.issuedAt))
            try store.addNote("Km 42 culvert washed out", to: name)
        }
        return store
    }

    private func records() throws -> DeviceRecordStore {
        let records = DeviceRecordStore(service: service, user: "officer-7")
        try records.save(DeviceRecord(deviceId: ShredOrderTests.fixture.deviceId, approved: true))
        return records
    }

    @Test(.needsRepoFiles) func aCheckedOrderDestroysEveryMissionRecordsItAndForgetsTheEnrollment() throws {
        let store = try missions(["kandor-roads", "kandor-bridges"])
        let records = try records()

        let result = ShredOrderAction.handle(ShredOrderTests.fixture.body, records: records, missions: store,
                                             keys: [ShredOrderTests.serverKey],
                                             now: ShredOrderTests.at(ShredOrderTests.fixture.issuedAt + 3))

        #expect(result == .destroyed(2))
        #expect((try? store.notes(in: "kandor-roads")) == nil && (try? store.notes(in: "kandor-bridges")) == nil)
        #expect(try store.shredRecords().map(\.reason) == [.shredOrder, .shredOrder])
        #expect(records.load() == nil)
    }

    @Test(.needsRepoFiles) func anOrderThatFailsTheCheckChangesNothing() throws {
        let store = try missions(["kandor-roads"])
        let records = try records()

        let result = ShredOrderAction.handle(ShredOrderTests.fixture.body, records: records, missions: store,
                                             keys: [P256.Signing.PrivateKey().publicKey],
                                             now: ShredOrderTests.at(ShredOrderTests.fixture.issuedAt))

        #expect(result == .ignored(.badSignature))
        #expect(try store.notes(in: "kandor-roads").isEmpty == false)
        #expect(try store.shredRecords().isEmpty)
        #expect(records.load() != nil)
    }

    @Test(.needsRepoFiles) func aPhoneThatIsNotEnrolledIgnoresEveryOrder() throws {
        let store = try missions(["kandor-roads"])

        let result = ShredOrderAction.handle(ShredOrderTests.fixture.body,
                                             records: DeviceRecordStore(service: service, user: "nobody"),
                                             missions: store, keys: [ShredOrderTests.serverKey],
                                             now: ShredOrderTests.at(ShredOrderTests.fixture.issuedAt))

        #expect(result == .ignored(.otherPhone))
        #expect(try store.shredRecords().isEmpty)
    }

    @Test(.needsRepoFiles) func anOrderWhileTheStoreIsClosedStillForgetsTheEnrollmentAndSaysSo() throws {
        let records = try records()

        let result = ShredOrderAction.handle(ShredOrderTests.fixture.body, records: records, missions: nil,
                                             keys: [ShredOrderTests.serverKey],
                                             now: ShredOrderTests.at(ShredOrderTests.fixture.issuedAt))

        #expect(result == .destroyed(0) && records.load() == nil)
    }
}
