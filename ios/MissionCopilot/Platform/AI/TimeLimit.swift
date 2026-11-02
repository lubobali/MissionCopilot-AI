import Foundation
import Synchronization

/// What a time-limited model call gives back. Only an answer within the limit can become facts; a stopped
/// call goes to a person for review (threat T06, #62).
enum ModelOutcome<T: Sendable>: Sendable {
    case answered(T)
    case stopped

    var usable: T? {
        if case .answered(let value) = self { value } else { nil }
    }

    var needsReview: Bool { usable == nil }
}

extension ModelOutcome: Equatable where T: Equatable {}

/// Races a model call against a timer. Whichever ends first decides, once: an answer is used; past the limit
/// the call is told to cancel and "stopped" comes back at once, without waiting for the call, so a call that
/// ignores cancel cannot hold the app. (The model's prefill cannot be cancelled at all; the input limit of
/// FactChecks bounds that part, #48.)
struct TimeLimit: Sendable {
    /// Normal pages take 3 to 6 s on the iPhone 13 Pro Max (#48): a wide margin, never an hour.
    static let model = TimeLimit(.seconds(20))

    let limit: Duration

    init(_ limit: Duration) {
        self.limit = limit
    }

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> ModelOutcome<T> {
        let gate = OnceGate<ModelOutcome<T>>()
        let limit = limit
        return try await withCheckedThrowingContinuation { continuation in
            gate.store(continuation)
            let work = Task {
                do {
                    gate.finish(.success(.answered(try await operation())))
                } catch {
                    gate.finish(.failure(error))
                }
            }
            gate.onAnswer(Task {
                try? await Task.sleep(for: limit)
                if gate.finish(.success(.stopped)) { work.cancel() }
            })
        }
    }
}

/// Resumes the waiting caller exactly once, whoever gets there first; the loser's result is dropped.
private final class OnceGate<Value: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<Value, any Error>?>(nil)
    private let timer = Mutex<Task<Void, Never>?>(nil)

    func store(_ waiting: CheckedContinuation<Value, any Error>) {
        continuation.withLock { $0 = waiting }
    }

    /// The timer to stop as soon as an answer arrives, so it does not linger for the whole limit.
    func onAnswer(_ timerTask: Task<Void, Never>) {
        timer.withLock { $0 = timerTask }
    }

    @discardableResult
    func finish(_ result: Result<Value, any Error>) -> Bool {
        guard let waiting = continuation.withLock({ value in
            defer { value = nil }
            return value
        }) else { return false }
        timer.withLock { $0?.cancel() }
        waiting.resume(with: result)
        return true
    }
}
