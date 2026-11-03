import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// The organization's server, built into the app (#90): its address and the public key(s) that sign
/// its mission packs and shred orders, pinned by key id. Anything signed by another key is refused,
/// and a build with a missing or wrong address says so instead of talking to a guess.
struct ServerConfigTests {
    static let key = P256.Signing.PrivateKey().publicKey
    static let rotated = P256.Signing.PrivateKey().publicKey

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test(arguments: ["abc", "zz", "MEUCIQ=="])
    func aKeyThatIsNotHexIsRefused(text: String) {
        #expect(throws: ServerConfig.Problem.badKey) {
            try ServerConfig.from(["MCServerScheme": "https", "MCServerHost": "kandor.example.org",
                                   "MCServerKeys": text], allowLocalHTTP: false)
        }
    }

    private func info(scheme: String = "https", host: String = "kandor-works.example.org",
                      keys: String? = nil) -> [String: Any] {
        ["MCServerScheme": scheme, "MCServerHost": host,
         "MCServerKeys": keys ?? Self.hex(Self.key.derRepresentation)]
    }

    @Test func aGoodBuildHasTheAddressAndThePinnedKey() throws {
        let config = try ServerConfig.from(info(), allowLocalHTTP: false)

        #expect(config.base.absoluteString == "https://kandor-works.example.org")
        #expect(config.key(for: ServerConfig.keyId(Self.key.derRepresentation))?.derRepresentation
                == Self.key.derRepresentation)
        #expect(config.allowLocalHTTP == false)
    }

    @Test func theKeyIdIsTheStartOfTheKeysHashLikeTheServers() {
        let der = Self.key.derRepresentation
        let hash = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        #expect(ServerConfig.keyId(der) == String(hash.prefix(16)))
    }

    @Test(.needsRepoFiles) func theKeyIdMatchesTheOneTheServerWroteIntoItsSignedPack() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/api/fixtures/pack-v2-kandor")
        let der = try #require(Data(base64Encoded: try String(contentsOf: fixture.appending(path: "public-key.der.b64"),
                                                               encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let signature = try JSONDecoder().decode([String: String].self,
                                                 from: Data(contentsOf: fixture.appending(path: "signature.json")))

        #expect(ServerConfig.keyId(der) == signature["keyId"])
    }

    @Test func aKeyThatIsNotPinnedIsNeverFound() throws {
        let config = try ServerConfig.from(info(), allowLocalHTTP: false)

        #expect(config.key(for: ServerConfig.keyId(Self.rotated.derRepresentation)) == nil)
        #expect(config.key(for: "0000000000000000") == nil)
    }

    @Test func twoPinnedKeysLetTheServerRotateItsKey() throws {
        let both = [Self.key, Self.rotated].map { Self.hex($0.derRepresentation) }.joined(separator: " ")

        let config = try ServerConfig.from(info(keys: both), allowLocalHTTP: false)

        #expect(config.key(for: ServerConfig.keyId(Self.rotated.derRepresentation))?.derRepresentation
                == Self.rotated.derRepresentation)
        #expect(config.key(for: ServerConfig.keyId(Self.key.derRepresentation))?.derRepresentation
                == Self.key.derRepresentation)
    }

    @Test(arguments: [
        (["MCServerScheme": "https"], ServerConfig.Problem.noAddress),
        (["MCServerScheme": "https", "MCServerHost": "", "MCServerKeys": "x"], .noAddress),
        (["MCServerScheme": "https", "MCServerHost": "kandor.example.org/path", "MCServerKeys": "x"], .badAddress),
        (["MCServerScheme": "ftp", "MCServerHost": "kandor.example.org", "MCServerKeys": "x"], .badAddress),
        (["MCServerScheme": "https", "MCServerHost": "kandor.example.org"], .noKeys),
        (["MCServerScheme": "https", "MCServerHost": "kandor.example.org", "MCServerKeys": " "], .noKeys),
        (["MCServerScheme": "https", "MCServerHost": "kandor.example.org", "MCServerKeys": "not-a-key"], .badKey)
    ])
    func aBrokenBuildSaysWhatIsMissing(info: [String: String], problem: ServerConfig.Problem) {
        #expect(throws: problem) { try ServerConfig.from(info, allowLocalHTTP: false) }
    }

    @Test func aKeyOfAnotherKindIsRefused() {
        let p384 = Self.hex(P384.Signing.PrivateKey().publicKey.derRepresentation)

        #expect(throws: ServerConfig.Problem.badKey) {
            try ServerConfig.from(info(keys: p384), allowLocalHTTP: false)
        }
    }

    @Test func plainHTTPIsOnlyForTheLocalServerInADebugBuild() throws {
        #expect(throws: ServerConfig.Problem.badAddress) {
            try ServerConfig.from(info(scheme: "http", host: "lubos-mac.local:8110"), allowLocalHTTP: false)
        }
        #expect(throws: ServerConfig.Problem.badAddress) {
            try ServerConfig.from(info(scheme: "http", host: "kandor-works.example.org"), allowLocalHTTP: true)
        }
        let local = try ServerConfig.from(info(scheme: "http", host: "lubos-mac.local:8110"), allowLocalHTTP: true)
        #expect(local.base.absoluteString == "http://lubos-mac.local:8110")
    }
}
