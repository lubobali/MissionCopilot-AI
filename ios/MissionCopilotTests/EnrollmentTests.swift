import CryptoKit
import Foundation
import Testing
import UIKit
@testable import MissionCopilot

/// Connecting this iPhone to its organization (#90): the one-time code from an admin, the chip key's
/// public half and a proof made with its private half go to the server; the phone then waits for a
/// manager's approval and learns it by asking with a signed request. Everything the screen shows comes
/// from these states, and they survive a restart.
@MainActor @Suite(.serialized) struct EnrollmentTests {
    let service = "missioncopilot.tests.enrollment.\(UUID().uuidString)"
    let signer = SoftwareEvidenceSigner()
    static let base = URL(string: "https://kandor-works.example.org")!
    static let code = "kq3X9vYb0M2tQ7wE1rLs_A"
    static let enrolled = Data(#"""
        {"id":"6f1d2c3a-1111-4000-8000-000000000007","userId":"officer-7","label":"x","status":"pending",
         "enrolledAt":"2026-11-03T12:00:00Z"}
        """#.utf8)

    private func enroller(_ transport: FakeTransport) -> Enroller {
        Enroller(base: Self.base, signer: signer, transport: transport)
    }

    private func model(_ transport: FakeTransport) -> EnrollmentModel {
        EnrollmentModel(enroller: enroller(transport), records: DeviceRecordStore(service: service, user: "officer-7"),
                        client: { deviceId in
                            ServerClient(base: Self.base, deviceId: deviceId, signer: signer,
                                         counter: RequestCounter(items: KeychainItems(service: service),
                                                                 account: deviceId),
                                         transport: transport)
                        })
    }

    // Sending the code

    @Test func theCodeTheKeyAndAProofMadeByTheKeyAreSent() async throws {
        let transport = FakeTransport(status: 201, body: Self.enrolled)

        let result = await enroller(transport).enroll(code: Self.code)

        #expect(result == .enrolled(deviceId: "6f1d2c3a-1111-4000-8000-000000000007"))
        let sent = try #require(transport.sent.first)
        #expect(sent.url?.absoluteString == "https://kandor-works.example.org/v1/devices/enroll")
        #expect(sent.httpMethod == "POST" && sent.value(forHTTPHeaderField: "X-Device-Signature") == nil)
        let body = try JSONDecoder().decode([String: String].self, from: try #require(sent.httpBody))
        let key = try signer.publicKeyDER()
        #expect(body["code"] == Self.code && body["publicKeyDER"] == key.base64EncodedString())
        let proofBytes = try #require(Data(base64Encoded: body["proof"] ?? ""))
        let proof = try P256.Signing.ECDSASignature(derRepresentation: proofBytes)
        #expect(try P256.Signing.PublicKey(derRepresentation: key)
            .isValidSignature(proof, for: DeviceSigning.enrollmentMessage(code: Self.code, publicKeyDER: key)))
    }

    @Test func spacesAroundAPastedCodeAreIgnored() async throws {
        let transport = FakeTransport(status: 201, body: Self.enrolled)

        _ = await enroller(transport).enroll(code: "  \(Self.code)\n")

        let body = try JSONDecoder().decode([String: String].self, from: try #require(transport.sent.first?.httpBody))
        #expect(body["code"] == Self.code)
    }

    @Test(arguments: ["", "short", "has spaces inside it!!", String(repeating: "a", count: 65)])
    func aCodeThatCannotBeRightIsNeverSent(code: String) async {
        let transport = FakeTransport(status: 201, body: Self.enrolled)

        #expect(await enroller(transport).enroll(code: code) == .badCode)
        #expect(transport.sent.isEmpty)
    }

    @Test(arguments: [(401, EnrollmentResult.badCode), (429, .slowDown(60)), (500, .failed)])
    func aRefusedCodeOrABusyServerSaysSo(status: Int, expected: EnrollmentResult) async {
        #expect(await enroller(FakeTransport(status: status)).enroll(code: Self.code) == expected)
    }

    @Test func aBrokenAnswerIsAFailureNotAnEnrollment() async {
        let transport = FakeTransport(status: 201, body: Data("not json".utf8))

        #expect(await enroller(transport).enroll(code: Self.code) == .failed)
    }

    @Test func noSignalIsOffline() async {
        #expect(await enroller(FakeTransport([.failure(URLError(.notConnectedToInternet))]))
            .enroll(code: Self.code) == .offline)
    }

    // The screen's states

    @Test func aNewPhoneIsNotEnrolled() {
        #expect(model(FakeTransport(status: 200)).state == .notEnrolled)
    }

    @Test func afterTheCodeThePhoneWaitsForApprovalEvenAfterARestart() async {
        let transport = FakeTransport(status: 201, body: Self.enrolled)
        let first = model(transport)

        await first.enroll(code: Self.code)

        #expect(first.state == .waitingForApproval)
        #expect(model(transport).state == .waitingForApproval)  // a new model: the same Keychain record
    }

    @Test func aWrongCodeStaysNotEnrolledAndSaysWhatToDo() async {
        let model = model(FakeTransport(status: 401))

        await model.enroll(code: Self.code)

        #expect(model.state == .notEnrolled)
        #expect(model.message == EnrollmentModel.text(.badCode))
    }

    @Test func approvalIsLearnedFromASignedRequestAndKept() async throws {
        let transport = FakeTransport([.success(.init(status: 201, body: Self.enrolled)),
                                       .success(.init(status: 401)), .success(.init(status: 200))])
        let model = model(transport)
        await model.enroll(code: Self.code)

        await model.checkApproval()
        #expect(model.state == .waitingForApproval)
        await model.checkApproval()

        #expect(model.state == .ready)
        let asked = try #require(transport.sent.last)
        #expect(asked.url?.path() == "/v1/devices/me" && asked.value(forHTTPHeaderField: "X-Device-Signature") != nil)
        #expect(self.model(transport).state == .ready)  // kept across a restart
    }

    @Test func checkingWithoutSignalKeepsWaitingAndSaysSo() async {
        let transport = FakeTransport([.success(.init(status: 201, body: Self.enrolled)),
                                       .failure(URLError(.notConnectedToInternet))])
        let model = model(transport)
        await model.enroll(code: Self.code)

        await model.checkApproval()

        #expect(model.state == .waitingForApproval && model.message == EnrollmentModel.text(.offline))
    }

    @Test func aShredOrderWhileCheckingIsHandedOnAndAnActedOrderEndsTheEnrollment() async {
        let order = Data(#"{"order":{}}"#.utf8)
        let transport = FakeTransport([.success(.init(status: 201, body: Self.enrolled)),
                                       .success(.init(status: 410, body: order))])
        var handed: Data?
        let model = EnrollmentModel(
            enroller: enroller(transport), records: DeviceRecordStore(service: service, user: "officer-7"),
            client: { deviceId in
                ServerClient(base: Self.base, deviceId: deviceId, signer: signer,
                             counter: RequestCounter(items: KeychainItems(service: service), account: deviceId),
                             transport: transport)
            },
            onShredOrder: { body in handed = body; return .destroyed(2) })
        await model.enroll(code: Self.code)

        await model.checkApproval()

        #expect(handed == order)
        #expect(model.state == .notEnrolled && model.message == EnrollmentModel.revoked)
    }

    @Test func aShredOrderThatFailsTheCheckChangesNothingAndSaysSo() async {
        let transport = FakeTransport([.success(.init(status: 201, body: Self.enrolled)),
                                       .success(.init(status: 410, body: Data("{}".utf8)))])
        let model = EnrollmentModel(
            enroller: enroller(transport), records: DeviceRecordStore(service: service, user: "officer-7"),
            client: { deviceId in
                ServerClient(base: Self.base, deviceId: deviceId, signer: signer,
                             counter: RequestCounter(items: KeychainItems(service: service), account: deviceId),
                             transport: transport)
            },
            onShredOrder: { _ in .ignored(.badSignature) })
        await model.enroll(code: Self.code)

        await model.checkApproval()

        #expect(model.state == .waitingForApproval && model.message == EnrollmentModel.text(.failed))
    }

    @Test func everyStateTellsThePersonWhatToDoNext() {
        for result in [EnrollmentResult.badCode, .slowDown(60), .offline, .failed] {
            #expect(!EnrollmentModel.text(result).isEmpty)
        }
        #expect(EnrollmentModel.text(.badCode).contains("admin"))
    }
}

/// The enrollment screen's words and icons: each state says what is going on and what to do next.
struct EnrollmentViewTests {
    @Test(arguments: [EnrollmentModel.State.notEnrolled, .waitingForApproval, .ready])
    func everyStateHasAnIconATitleAndWhatToDo(state: EnrollmentModel.State) {
        #expect(UIImage(systemName: EnrollmentView.icon(state)) != nil)
        #expect(!EnrollmentView.title(state).isEmpty && !EnrollmentView.explanation(state).isEmpty)
    }

    @Test func eachStateSaysSomethingDifferent() {
        let states: [EnrollmentModel.State] = [.notEnrolled, .waitingForApproval, .ready]

        #expect(Set(states.map(EnrollmentView.title)).count == 3)
        #expect(Set(states.map(EnrollmentView.icon)).count == 3)
    }
}
