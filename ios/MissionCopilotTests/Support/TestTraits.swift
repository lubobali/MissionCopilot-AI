import Foundation
import Testing

/// The repository on the Mac that built the tests. The iPhone has none of its files.
enum Repo {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static var isHere: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("docs").path) }
}

extension Trait where Self == ConditionTrait {
    /// For tests that read the repository's own files (shared fixtures, the public key): Mac only.
    static var needsRepoFiles: Self {
        .enabled(if: Repo.isHere, "Reads the repository's files, which only the Mac has")
    }
}

/// GRDB's pause signal reaches every pausable store in the app at once. Suites that post it, and suites
/// whose stores pause on it, take turns through one lock, so a fake lock never pauses another suite's
/// store mid-test (seen on the iPhone run, #74). Every other suite still runs in parallel.
struct TakesTurnsWithThePause: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }  // the suite itself: its tests take turns
        try await PauseTurns.shared.take(function)
    }
}

extension Trait where Self == TakesTurnsWithThePause {
    static var takesTurnsWithThePause: Self { Self() }
}

private actor PauseTurns {
    static let shared = PauseTurns()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func take(_ body: @Sendable () async throws -> Void) async throws {
        if busy {
            await withCheckedContinuation { waiting.append($0) }  // handed over still busy
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        try await body()
    }
}
