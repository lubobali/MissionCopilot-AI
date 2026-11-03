import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// What the server wrote (docs/api/fixtures/device-signing.json): fixed inputs and its exact bytes.
private struct SigningFixture: Decodable {
    let enrollment: [EnrollmentCase]
    let requests: [RequestCase]
}

private struct EnrollmentCase: Decodable {
    let code: String, publicKeyDER: Data, message: Data
}

private struct RequestCase: Decodable {
    let method: String, path: String, deviceId: String, seq: Int, time: Int, body: Data, message: Data

    enum CodingKeys: String, CodingKey {
        case method, path, deviceId, seq, time = "at", body, message
    }

    var request: SignedRequest {
        SignedRequest(method: method, path: path, deviceId: deviceId, seq: seq, time: time, body: body)
    }
}

private func request(_ method: String = "GET", path: String = "/v1/x", seq: Int = 1,
                     body: Data = Data()) -> SignedRequest {
    SignedRequest(method: method, path: path, deviceId: "d", seq: seq, time: 1, body: body)
}

/// What the phone signs, byte for byte like the server (docs/security.md, #90). The server wrote fixed
/// inputs and the exact bytes it builds from them; the app must build the same bytes. The app's own
/// signatures go back the other way: the Python server checks them (docs/api/fixtures/
/// device-signing-app.json, written by the last test when SIGNING_FIXTURE_DIR is set).
struct DeviceSigningTests {
    private static let fixture: SigningFixture = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/api/fixtures/device-signing.json")
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(SigningFixture.self, from: Data(contentsOf: url))
    }()

    @Test(.needsRepoFiles) func theEnrollmentProofIsTheServersBytes() {
        for entry in Self.fixture.enrollment {
            #expect(DeviceSigning.enrollmentMessage(code: entry.code, publicKeyDER: entry.publicKeyDER)
                    == entry.message)
        }
    }

    @Test(.needsRepoFiles) func everyRequestMessageIsTheServersBytes() throws {
        for entry in Self.fixture.requests {
            #expect(try DeviceSigning.requestMessage(entry.request) == entry.message, "\(entry.path)")
        }
    }

    @Test func theBodyIsSignedByItsHashSoAChangedBodyChangesTheMessage() throws {
        let first = try DeviceSigning.requestMessage(request("POST", body: Data("a".utf8)))
        let second = try DeviceSigning.requestMessage(request("POST", body: Data("b".utf8)))

        #expect(first != second)
    }

    @Test(arguments: ["/v1/missions/a%20b", "v1/no-leading-slash", "/v1/x\n/v1/y", ""])
    func aPathTheServerCouldReadDifferentlyIsRefused(path: String) {
        #expect(throws: DeviceSigning.Failure.badPath) { try DeviceSigning.requestMessage(request(path: path)) }
    }

    @Test(arguments: [0, -1])
    func aSequenceNumberBelowOneIsRefused(seq: Int) {
        #expect(throws: DeviceSigning.Failure.badSequence) { try DeviceSigning.requestMessage(request(seq: seq)) }
    }

    @Test(arguments: ["get", "DELETE"])
    func onlyTheMethodsThePhoneUsesAreSigned(method: String) {
        #expect(throws: DeviceSigning.Failure.badMethod) { try DeviceSigning.requestMessage(request(method)) }
    }

    /// Signs every fixture request with a software key (the same format as the chip) and, when asked,
    /// writes them for the Python server to check.
    @Test(.needsRepoFiles) func theAppsSignaturesAreValidAndCanBeSentToTheServer() throws {
        let signer = SoftwareEvidenceSigner()
        let publicKey = try P256.Signing.PublicKey(derRepresentation: signer.publicKeyDER())
        var signed: [[String: String]] = []
        for entry in Self.fixture.requests {
            let signature = try signer.sign(entry.message)
            #expect(publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature),
                                               for: entry.message))
            signed.append(["message": entry.message.base64EncodedString(),
                           "signature": signature.base64EncodedString()])
        }
        if let folder = ProcessInfo.processInfo.environment["SIGNING_FIXTURE_DIR"] {
            let out: [String: Any] = ["publicKeyDER": try signer.publicKeyDER().base64EncodedString(),
                                      "signed": signed]
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(filePath: folder).appending(path: "device-signing-app.json"))
        }
    }
}
