#if DEBUG
import Observation
import SwiftUI
import UIKit

/// The phone run of the store proof (#74): one Face ID, the proof, then the lock test. Kept outside the
/// screen, because locking the phone also locks the app and removes the screen until Face ID.
@MainActor @Observable
final class StoreProofLab {
    static let shared = StoreProofLab()

    private(set) var proof: StoreProofReport?
    private(set) var lockChecks: [StoreProofReport.Check] = []
    private(set) var lockTest: StoreLockTest?
    private(set) var message = ""
    /// A lock test that never finished: iOS killed the app while it ran.
    private(set) var lastRunKilled = StoreLockTest.unfinished(in: StoreProof.live().outbox)

    private var loop: Task<Void, Never>?
    private var background: UIBackgroundTaskIdentifier = .invalid

    func runProof() async {
        do {
            let context = try await LocalAuthenticator().authenticate()
            proof = StoreProof.live().run(context: context, device: Self.device)
            message = ""
        } catch {
            message = "Not run: \(error)"
        }
    }

    func startLockTest() async {
        guard lockTest == nil else { return }
        do {
            let live = StoreProof.live()
            let context = try await LocalAuthenticator().authenticate()
            let missions = try UserStore.openMissions(user: StoreProof.user, in: live.base, keys: live.keys,
                                                      vault: live.vault, context: context).missions
            let file = live.databaseFile
            let test = try StoreLockTest(missions: missions, outbox: live.outbox, signals: .default) {
                (try? FileHandle(forReadingFrom: file).read(upToCount: 16)) != nil
            }
            lockTest = test
            lockChecks = []
            lastRunKilled = false
            // Keeps the writes going for about 30 s after the lock, so the pause is what stops them.
            background = UIApplication.shared.beginBackgroundTask(withName: "store lock test") { [weak self] in
                self?.endBackground()
            }
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    self?.lockTest?.tick()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        } catch {
            message = "Lock test not started: \(error)"
        }
    }

    func finishLockTest() {
        loop?.cancel()
        loop = nil
        endBackground()
        lockChecks = lockTest?.finish() ?? []
        lockTest = nil
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    private static var device: String {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: info.machine) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }
            ?? "iPhone"
        return "\(model), iOS \(UIDevice.current.systemVersion), Mission Copilot (Debug)"
    }
}

struct StoreProofView: View {
    private let lab = StoreProofLab.shared

    var body: some View {
        List {
            if lab.lastRunKilled {
                Text("The last lock test never finished: iOS stopped the app while it ran.")
                    .foregroundStyle(.red)
            }
            Section("1. Store proof") {
                Button("Run store proof") { Task { await lab.runProof() } }
                if let proof = lab.proof {
                    Text(proof.passed ? "All checks passed" : "Some checks failed").bold()
                    checks(proof.checks)
                }
            }
            Section("2. Lock test") {
                if let test = lab.lockTest {
                    Text("Running: \(test.written) written, \(test.refused) refused")
                    Text("Now lock the phone, wait 30 seconds, unlock, come back here, then tap Finish.")
                        .font(.footnote)
                    Button("Finish lock test", action: lab.finishLockTest)
                } else {
                    Button("Start lock test") { Task { await lab.startLockTest() } }
                }
                checks(lab.lockChecks)
            }
            if !lab.message.isEmpty { Text(lab.message).font(.footnote) }
        }
        .navigationTitle("Store proof (#74)")
    }

    private func checks(_ checks: [StoreProofReport.Check]) -> some View {
        ForEach(checks, id: \.name) { check in
            VStack(alignment: .leading) {
                Label(check.name, systemImage: check.passed ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(check.passed ? .green : .red)
                Text(check.detail).font(.caption.monospaced())
            }
        }
    }
}
#endif
