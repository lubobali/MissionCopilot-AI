import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// Found on the iPhone, Nov 11 2026: a shred order and a new connection deleted the evidence key but kept the
/// Face ID approval key. The server keeps that key for the revoked phone (one approval key belongs to one phone,
/// #171), so the newly connected phone could never register it and its approved report waited forever. Both
/// keys now go together.
@Suite(.serialized)
struct PhoneKeysTests {
    struct Planted {
        let keys: PhoneKeys
        let evidence = KeychainItems(service: "test.phonekeys.evidence")
        let approval = KeychainItems(service: "test.phonekeys.approval")
        let user: String

        init() {
            user = "phone-keys-\(UUID().uuidString)"
            keys = PhoneKeys(user: user, evidenceService: evidence.service, approvalService: approval.service)
        }
    }

    static func plant(_ items: KeychainItems, _ user: String) throws {
        let access = try #require(SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [], nil))
        #expect(try items.add(Data("blob".utf8), account: user, access: access))
    }

    @Test func forgettingDeletesTheEvidenceKeyAndTheApprovalKey() throws {
        let phone = Planted()
        try Self.plant(phone.evidence, phone.user)
        try Self.plant(phone.approval, phone.user)

        phone.keys.forget()

        #expect(try phone.evidence.load(phone.user) == nil)
        #expect(try phone.approval.load(phone.user) == nil, "the approval key goes too")
    }

    @Test func forgettingWithNoKeysIsFine() {
        Planted().keys.forget()
    }
}
