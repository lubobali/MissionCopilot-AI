import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// The phone's checks on a mission pack, the same as the server's (pack_format.verify_pack, #91, threat
/// T51): a pinned key signed the pack label and the exact manifest bytes; the contract's rules hold even
/// after a genuine signature; the key id inside matches; the pack has not expired and this app is new
/// enough; every file is exactly what the manifest says. The good and bad examples are the same file the
/// server's tests read (docs/api/fixtures/pack-manifest-cases.json).
struct PackVerifierTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let fixture = repo.appendingPathComponent("docs/api/fixtures/pack-v2-kandor")
    static let now = Date(timeIntervalSince1970: 1_793_000_000)  // inside the fixture's validity

    static func file(_ path: String) -> Data {
        // swiftlint:disable:next force_try
        try! Data(contentsOf: fixture.appending(path: path))
    }

    static var fixtureKey: P256.Signing.PublicKey {
        let text = (String(bytes: file("public-key.der.b64"), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // swiftlint:disable:next force_try force_unwrapping
        return try! P256.Signing.PublicKey(derRepresentation: Data(base64Encoded: text)!)
    }

    static func pinned(_ keys: [P256.Signing.PublicKey]) -> (String) -> P256.Signing.PublicKey? {
        { id in keys.first { ServerConfig.keyId($0.derRepresentation) == id } }
    }

    private func verify(_ manifest: Data = file("manifest.json"), _ signature: Data = file("signature.json"),
                        keys: [P256.Signing.PublicKey] = [fixtureKey], now: Date = now,
                        app: String = "0.5.0") throws(PackRefusal) -> PackManifest {
        try PackVerifier.verify(manifest: manifest, signature: signature, keys: Self.pinned(keys), now: now,
                                appVersion: app)
    }

    private func refusal(_ call: () throws -> PackManifest) -> PackRefusal? {
        do {
            _ = try call()
            return nil
        } catch {
            return error as? PackRefusal
        }
    }

    /// A manifest signed with the pack label by `key`, and its signature, as the server sends them.
    private func signed(_ manifest: Data, by key: P256.Signing.PrivateKey, label: Bool = true,
                        keyId: String? = nil, algorithm: String = "ecdsa-p256-sha256") throws -> Data {
        let message = (label ? PackVerifier.domain : Data()) + manifest
        let signature = try key.signature(for: message).derRepresentation.base64EncodedString()
        let id = keyId ?? ServerConfig.keyId(key.publicKey.derRepresentation)
        return try JSONSerialization.data(withJSONObject: ["keyId": id, "algorithm": algorithm, "signature": signature])
    }

    // The real signed pack

    @Test(.needsRepoFiles) func theServersSignedKandorPackVerifies() throws {
        let manifest = try verify()

        #expect(manifest.missionId == "6f1d2c3a-0000-4000-8000-000000000001" && manifest.version == 1)
        #expect(manifest.orgId == "kandor-works" && manifest.files.count == 12)
    }

    @Test(.needsRepoFiles) func everyFileOfTheKandorPackIsWhatTheManifestSays() throws {
        for entry in try verify().files {
            try PackVerifier.check(entry, data: Self.file("files/\(entry.sha256)"))
        }
    }

    @Test(.needsRepoFiles, arguments: [0, 100, 1000])
    func oneChangedByteInTheManifestIsRefused(position: Int) {
        var manifest = Self.file("manifest.json")
        manifest[position] ^= 0x01

        #expect(refusal { try verify(manifest) } == .badSignature)
    }

    @Test(.needsRepoFiles) func aFileWithTheWrongSizeOrContentIsRefused() throws {
        let entry = try #require(try verify().files.first)
        let data = Self.file("files/\(entry.sha256)")
        var changed = data
        changed[0] ^= 0x01

        #expect(throws: PackRefusal.wrongSize) { try PackVerifier.check(entry, data: data + Data("x".utf8)) }
        #expect(throws: PackRefusal.wrongHash) { try PackVerifier.check(entry, data: changed) }
    }

    // Keys and signatures

    @Test(.needsRepoFiles) func aPackFromAKeyThatIsNotPinnedIsRefused() {
        #expect(refusal { try verify(keys: [P256.Signing.PrivateKey().publicKey]) } == .unknownKey)
    }

    @Test(.needsRepoFiles) func aSignatureClaimingThePinnedKeysIdButMadeByAnotherIsRefused() throws {
        let forged = try signed(Self.file("manifest.json"), by: P256.Signing.PrivateKey(),
                                keyId: ServerConfig.keyId(Self.fixtureKey.derRepresentation))

        #expect(refusal { try verify(Self.file("manifest.json"), forged) } == .badSignature)
    }

    @Test(.needsRepoFiles) func aSignatureWithoutThePackLabelIsRefused() throws {
        let key = P256.Signing.PrivateKey()
        let unlabelled = try signed(Self.file("manifest.json"), by: key, label: false)

        #expect(refusal { try verify(Self.file("manifest.json"), unlabelled, keys: [key.publicKey]) } == .badSignature)
    }

    @Test(.needsRepoFiles) func theSignatureMustNameTheSameKeyAsTheManifest() throws {
        let other = P256.Signing.PrivateKey()  // pinned too, but the manifest names the fixture's key
        let signature = try signed(Self.file("manifest.json"), by: other)

        #expect(refusal { try verify(Self.file("manifest.json"), signature, keys: [Self.fixtureKey, other.publicKey]) }
                == .keyMismatch)
    }

    @Test(.needsRepoFiles, arguments: [#"{"keyId":"6763784ff41d7ab5","algorithm":"rsa","signature":"AA=="}"#,
                                       #"{"keyId":"6763784ff41d7ab5","algorithm":"ecdsa-p256-sha256","signature":"!"}"#,
                                       "not json", "{}"])
    func aGarbledOrForeignSignatureIsRefused(signature: String) {
        let found = refusal { try verify(Self.file("manifest.json"), Data(signature.utf8)) }

        #expect(found == .badSignature || found == .unknownKey)
    }

    // Time and app version

    @Test(.needsRepoFiles) func anExpiredPackIsRefusedEvenWhenGenuine() {
        let later = Date(timeIntervalSince1970: 2_200_000_000)  // 2039: past the fixture's ten years

        #expect(refusal { try verify(now: later) } == .expired)
    }

    @Test(.needsRepoFiles, arguments: ["0.4.9", "0.1.0", "0.4"])
    func anAppOlderThanThePackNeedsIsRefused(app: String) {
        #expect(refusal { try verify(app: app) } == .appTooOld)
    }

    @Test(.needsRepoFiles, arguments: ["0.5", "0.5.0", "0.10.0", "1.0"])
    func anAppAsNewOrNewerIsFine(app: String) throws {
        #expect(try verify(app: app).version == 1)
    }

    @Test func thisBuildIsNewEnoughForThePacksTheServerPublishes() {
        #expect(PackVerifier.appVersion == "0.5.0")
    }

    // The contract's rules, after a genuine signature

    /// Read with JSONSerialization, as the verifier reads a manifest, so number types stay as written.
    private static var cases: [String: Any] {
        let url = repo.appendingPathComponent("docs/api/fixtures/pack-manifest-cases.json")
        // swiftlint:disable:next force_try force_cast
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    private static var good: Any { cases["good"] as Any }
    private static var bad: [Any] { cases["bad"] as? [Any] ?? [] }

    @Test(.needsRepoFiles) func theCodeAcceptsWhatTheContractAccepts() throws {
        #expect(try PackVerifier.rules(Self.good).version == 1)
    }

    @Test(.needsRepoFiles) func theCodeRefusesEveryManifestTheContractRefuses() {
        #expect(Self.bad.count == 20)
        for (index, bad) in Self.bad.enumerated() {
            #expect(throws: PackRefusal.malformed, "bad case \(index)") { try PackVerifier.rules(bad) }
        }
    }

    @Test(.needsRepoFiles, arguments: ["version", "formatVersion"])
    func trueOrADecimalIsNotAWholeNumber(field: String) throws {
        for value in ["true", "2.0"] {
            let good = try JSONSerialization.data(withJSONObject: Self.good)
            let text = (String(bytes: good, encoding: .utf8) ?? "")
                .replacingOccurrences(of: "\"\(field)\":\(field == "version" ? 1 : 2)", with: "\"\(field)\":\(value)")
            #expect(throws: PackRefusal.malformed) {
                try PackVerifier.rules(try JSONSerialization.jsonObject(with: Data(text.utf8)))
            }
        }
    }

    @Test(.needsRepoFiles) func aGenuineSignatureNamingAnotherAlgorithmIsRefused() throws {
        // A pinned key really signed it, under its own id: only the algorithm name is wrong.
        let key = P256.Signing.PrivateKey()
        let manifest = Self.file("manifest.json")
        let other = try signed(manifest, by: key, algorithm: "rsa-sha1")

        #expect(refusal { try verify(manifest, other, keys: [key.publicKey]) } == .badSignature)
    }

    @Test(.needsRepoFiles) func filesThatAreEachFineButTogetherOver50MBAreRefused() throws {
        var manifest = try #require(Self.good as? [String: Any])
        let big: [String: Any] = ["sha256": String(repeating: "a", count: 64), "size": PackVerifier.maxFileBytes,
                                  "mediaType": "application/pdf"]
        manifest["files"] = (0..<3).map { big.merging(["path": "documents/d\($0).pdf"]) { first, _ in first } }

        #expect(throws: PackRefusal.malformed) { try PackVerifier.rules(manifest) }
    }

    @Test(.needsRepoFiles) func aGenuineSignatureOverAManifestThatBreaksTheRulesIsStillRefused() throws {
        let key = P256.Signing.PrivateKey()
        var bad = try #require(Self.good as? [String: Any])
        bad["keyId"] = ServerConfig.keyId(key.publicKey.derRepresentation)
        bad["extra"] = 1
        let manifest = try JSONSerialization.data(withJSONObject: bad)

        #expect(refusal { try verify(manifest, try signed(manifest, by: key), keys: [key.publicKey]) } == .malformed)
    }
}
