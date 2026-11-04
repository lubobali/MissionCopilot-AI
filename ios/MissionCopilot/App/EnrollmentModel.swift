import Foundation
import Observation

/// The enrollment screen's states (#90): not enrolled, waiting for a manager's approval, ready. The
/// state lives in the Keychain record, so it survives a restart; approval is learned by asking the
/// server with a signed request (a pending phone is refused, an approved one sees itself).
@MainActor @Observable final class EnrollmentModel {
    enum State: Equatable { case notEnrolled, waitingForApproval, ready }

    private(set) var state: State
    private(set) var message: String?
    private(set) var busy = false
    private let enroller: Enroller
    private let records: DeviceRecordStore
    private let client: (String) -> ServerClient
    private let onShredOrder: (Data) -> ShredOrderAction.Result

    static let revoked =
        "This iPhone was revoked, so its missions were destroyed. Ask your admin before connecting again."

    /// - Parameter onShredOrder: checks a shred order and acts on it only if it passes (ShredOrderAction).
    init(enroller: Enroller, records: DeviceRecordStore, client: @escaping (String) -> ServerClient,
         onShredOrder: @escaping (Data) -> ShredOrderAction.Result = { _ in .ignored(.notAnOrder) }) {
        self.enroller = enroller
        self.records = records
        self.client = client
        self.onShredOrder = onShredOrder
        state = Self.state(of: records.load())
    }

    func enroll(code: String) async {
        busy = true
        defer { busy = false }
        let result = await enroller.enroll(code: code)
        guard case .enrolled(let deviceId) = result else {
            message = Self.text(result)
            return
        }
        do {
            try records.save(DeviceRecord(deviceId: deviceId, approved: false))
            state = .waitingForApproval
            message = nil
        } catch {
            message = Self.text(.failed)
        }
    }

    func checkApproval() async {
        guard var record = records.load(), !record.approved else { return }
        busy = true
        defer { busy = false }
        switch await client(record.deviceId).get("/v1/devices/me") {
        case .success:
            record.approved = true
            try? records.save(record)
            state = .ready
            message = nil
        case .refused: message = "Not approved yet. Ask your manager to approve this iPhone."
        case .offline: message = Self.text(.offline)
        case .slowDown(let seconds): message = Self.text(.slowDown(seconds))
        case .busy: message = Self.text(.busy)
        case .shredOrder(let body):
            if case .destroyed = onShredOrder(body) {
                state = .notEnrolled
                message = Self.revoked
            } else {
                message = Self.text(.failed)  // an order that fails the check changes nothing
            }
        default: message = Self.text(.failed)
        }
    }

    private static func state(of record: DeviceRecord?) -> State {
        guard let record else { return .notEnrolled }
        return record.approved ? .ready : .waitingForApproval
    }

    /// Every outcome tells the person what to do next.
    static func text(_ result: EnrollmentResult) -> String {
        switch result {
        case .enrolled: "Connected. Waiting for your manager to approve this iPhone."
        case .badCode: "That code did not work. Ask your admin for a new one; a code works once, for 15 minutes."
        case .slowDown(let seconds): "Too many tries. Wait \(seconds) seconds, then try again."
        case .busy: "The server is restarting. Try again in a moment."
        case .offline: "No connection. Connect to Wi-Fi or mobile data, then try again."
        case .failed: "Something went wrong on the way. Try again in a moment."
        }
    }
}
