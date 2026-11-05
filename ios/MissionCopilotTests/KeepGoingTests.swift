import Foundation
import Testing
@testable import MissionCopilot

/// Keeping a pack download going after the user leaves the app (#91). The work starts at once; the
/// first way the system grants carries its progress (BGContinuedProcessingTask shows it to the user);
/// when the system wants the time back the work is stopped, and it goes on later from the bytes on disk.
/// The Simulator has no background tasks, so the real BGContinuedProcessingTask is proven on the iPhone
/// (#94); here it must refuse cleanly and leave the download to the short background time.
@MainActor
@Suite(.timeLimit(.minutes(1)))  // work that is never stopped is a failure, not a hang
struct KeepGoingTests {
    final class FakeLease: BackgroundLease, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var steps: [String] = []
        func progress(done: Int, total: Int) { lock.withLock { steps.append("\(done)/\(total)") } }
        func end(success: Bool) { lock.withLock { steps.append("end \(success)") } }
        var seen: [String] { lock.withLock { steps } }
    }

    final class FakeRunway: BackgroundRunway, @unchecked Sendable {
        let grants: Bool
        let lease = FakeLease()
        private(set) var asked = 0
        private(set) var expire: (@Sendable () -> Void)?

        init(grants: Bool) { self.grants = grants }

        func begin(title: String, subtitle: String, expire: @escaping @Sendable () -> Void) -> BackgroundLease? {
            asked += 1
            self.expire = expire
            return grants ? lease : nil
        }
    }

    @Test func theFirstWayTheSystemGrantsCarriesTheWorkAndTheOthersAreNotAsked() async {
        let refused = FakeRunway(grants: false), granted = FakeRunway(grants: true), spare = FakeRunway(grants: true)

        let outcome = await KeepGoing.run(title: "t", subtitle: "s", runways: [refused, granted, spare]) { report in
            report(5, 10)
            report(10, 10)
            return .paused(.offline)
        }

        #expect(outcome == .paused(.offline))
        #expect(refused.asked == 1 && granted.asked == 1 && spare.asked == 0)
        #expect(granted.lease.seen == ["5/10", "10/10", "end false"])
    }

    @Test func aFinishedPackEndsTheLeaseAsASuccess() async throws {
        let runway = FakeRunway(grants: true)
        let rig = try PackDownloaderTests.Rig()

        let outcome = await KeepGoing.run(title: "t", subtitle: "s", runways: [runway]) { _ in await rig.run() }

        guard case .verified = outcome else { Issue.record("\(outcome)"); return }
        #expect(runway.lease.seen.last == "end true")
    }

    @Test func withNoWayGrantedTheWorkStillRunsWhileTheAppIsOpen() async {
        let outcome = await KeepGoing.run(title: "t", subtitle: "s", runways: [FakeRunway(grants: false)]) { _ in
            .failed(.notFound)
        }

        #expect(outcome == .failed(.notFound))
    }

    @Test func whenTheSystemWantsTheTimeBackTheWorkIsStopped() async {
        let runway = FakeRunway(grants: true)

        let outcome = await KeepGoing.run(title: "t", subtitle: "s", runways: [runway]) { _ in
            await MainActor.run { runway.expire?() }
            while !Task.isCancelled { await Task.yield() }
            return .paused(.interrupted)
        }

        #expect(outcome == .paused(.interrupted))
        #expect(runway.lease.seen == ["end false"])
    }

    @Test func theRealContinuedProcessingTaskRefusesCleanlyOnTheSimulator() async {
        #if targetEnvironment(simulator)
        let lease = await ContinuedProcessingRunway().begin(title: "t", subtitle: "s") {}
        #expect(lease == nil)
        #endif
    }

    @Test func theShortBackgroundTimeIsGrantedWhileTheAppIsOpenAndGivenBack() throws {
        let lease = try #require(BackgroundTimeRunway().begin(title: "t", subtitle: "s") {})

        lease.progress(done: 1, total: 2)
        lease.end(success: true)
        lease.end(success: true)  // twice is harmless
    }

    @Test func everyContinuedTaskIdIsNewAndUnderTheOnePermittedInInfoPlist() throws {
        let permitted = try #require(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers")
            as? [String])
        let prefix = try #require(permitted.first?.dropLast().description)  // "...pack." without the "*"
        let first = ContinuedProcessingRunway.newIdentifier(), second = ContinuedProcessingRunway.newIdentifier()

        let bundle = try #require(Bundle.main.bundleIdentifier)
        #expect(permitted == ["\(bundle).pack.*"])
        #expect(first?.hasPrefix(prefix) == true && second?.hasPrefix(prefix) == true && first != second)
    }

    /// #104: the Staging build has its own bundle id, and Info.plist permits "<bundle id>.pack.*". An id
    /// written into the code would be refused there, and no download would keep going outside the app.
    @Test(arguments: ["com.lubobali.missioncopilot", "com.lubobali.missioncopilot.staging"])
    func theContinuedTaskIdComesFromTheBuildsOwnBundleId(bundle: String) throws {
        let identifier = try #require(ContinuedProcessingRunway.newIdentifier(bundle: bundle))

        #expect(identifier.hasPrefix("\(bundle).pack."))
        #expect(UUID(uuidString: String(identifier.dropFirst("\(bundle).pack.".count))) != nil)
    }

    @Test func withNoBundleIdThereIsNoContinuedTaskAndTheShortTimeIsNext() {
        #expect(ContinuedProcessingRunway.newIdentifier(bundle: nil) == nil)
    }
}
