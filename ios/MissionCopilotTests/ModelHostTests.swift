import Foundation
import Testing
@testable import MissionCopilot

/// Loading the model (#136, step 6.4.3): only after its signature check says verified; once, when first
/// needed, even if two calls arrive together; dropped when the app goes to the background or iOS warns
/// about memory, and loaded again (and checked again) on the next call.
struct ModelHostTests {
    actor Calls {
        var checks = 0, loads = 0, clears = 0
        func check() { checks += 1 }
        func load() { loads += 1 }
        func clear() { clears += 1 }
    }

    struct Echo: ModelEngine {
        func generate(_ request: ModelRequest) async throws -> String { "{}" }
    }

    static func host(_ calls: Calls, state: BundledModel.State = .verified(files: 7), loadFails: Bool = false,
                     loadTakes: Duration = .zero) -> ModelHost {
        ModelHost(
            check: { await calls.check(); return state },
            load: { _ in
                await calls.load()
                if loadTakes > .zero { try await Task.sleep(for: loadTakes) }
                if loadFails { throw CocoaError(.fileReadCorruptFile) }
                return Echo()
            },
            clearMemory: { await calls.clear() },
            folder: URL(filePath: "/app/Models/LFM2.5-1.2B-Instruct-4bit"))
    }

    static let request = ModelRequest(prompt: "p", schema: "{}", maxTokens: 8)

    @Test func aVerifiedModelLoadsOnceWhenFirstNeeded() async throws {
        let calls = Calls()
        let host = Self.host(calls)
        #expect(await calls.loads == 0, "nothing loads before it is needed")

        _ = try await host.generate(Self.request)
        _ = try await host.generate(Self.request)

        #expect(await calls.checks == 1)
        #expect(await calls.loads == 1)
    }

    @Test func twoCallsAtOnceLoadItOnce() async throws {
        let calls = Calls()
        let host = Self.host(calls, loadTakes: .milliseconds(100))

        async let first = host.generate(Self.request)
        async let second = host.generate(Self.request)
        _ = try await (first, second)

        #expect(await calls.loads == 1)
    }

    @Test(arguments: [(BundledModel.State.notInThisBuild, ModelUnavailable.notInThisBuild),
                      (.refused(.unsigned), .failedCheck)])
    func aModelThatIsNotVerifiedIsNeverLoaded(state: BundledModel.State, why: ModelUnavailable) async {
        let calls = Calls()

        await #expect(throws: why) { try await Self.host(calls, state: state).generate(Self.request) }
        #expect(await calls.loads == 0)
    }

    @Test func aLoadThatFailsSaysSoAndIsTriedAgainNextTime() async {
        let calls = Calls()
        let host = Self.host(calls, loadFails: true)

        await #expect(throws: ModelUnavailable.couldNotLoad) { try await host.generate(Self.request) }
        await #expect(throws: ModelUnavailable.couldNotLoad) { try await host.generate(Self.request) }
        #expect(await calls.loads == 2)
    }

    @Test func releasingDropsItAndFreesMemoryThenTheNextCallChecksAndLoadsAgain() async throws {
        let calls = Calls()
        let host = Self.host(calls)
        _ = try await host.generate(Self.request)
        let before = await calls.clears

        await host.release()
        #expect(await host.isLoaded == false)
        #expect(await calls.clears == before + 1)

        _ = try await host.generate(Self.request)
        #expect(await calls.checks == 2)
        #expect(await calls.loads == 2)
    }

    @Test func memoryIsFreedAfterEveryAnswer() async throws {
        // MLX keeps freed buffers in a cache that grows with each run unless cleared (checked Nov 6).
        let calls = Calls()
        let host = Self.host(calls)

        _ = try await host.generate(Self.request)
        _ = try await host.generate(Self.request)

        #expect(await calls.clears == 2)
    }

    @Test(arguments: ["background", "memoryWarning"])
    @MainActor
    func goingToTheBackgroundOrAMemoryWarningReleasesIt(event: String) async throws {
        let calls = Calls()
        let host = Self.host(calls)
        let center = NotificationCenter()
        let watcher = ModelMemoryWatcher(host: host, center: center)
        _ = try await host.generate(Self.request)

        center.post(name: event == "background" ? ModelMemoryWatcher.background : ModelMemoryWatcher.memoryWarning,
                    object: nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await host.isLoaded == false)
        withExtendedLifetime(watcher) {}
    }

    /// Found on the iPhone (#136): a second test after the background took 3.6 s like a warm one, so the time
    /// alone cannot say whether the model was dropped. The host says whether the last call loaded it.
    @Test func theHostSaysWhetherTheLastCallLoadedTheModel() async throws {
        let calls = Calls()
        let host = Self.host(calls)

        _ = try await host.generate(Self.request)
        guard case .loaded = await host.lastLoad else { Issue.record("first call loads"); return }

        _ = try await host.generate(Self.request)
        #expect(await host.lastLoad == .alreadyLoaded)

        await host.release()
        _ = try await host.generate(Self.request)
        guard case .loaded = await host.lastLoad else { Issue.record("after a release it loads again"); return }
    }
}
