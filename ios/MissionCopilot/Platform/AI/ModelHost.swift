import Foundation
import UIKit

/// Holds the loaded model (#136, step 6.4.3). It checks the bundled model's signature and loads it only
/// when a call first needs it, once even if two calls arrive together; a model that is not verified is never
/// loaded (T46). After every answer it frees the GPU cache MLX keeps, and `release()` drops the model (the
/// app went to the background, or iOS warned about memory); the next call checks and loads it again.
actor ModelHost: ModelEngine {
    typealias Check = @Sendable () async -> BundledModel.State
    typealias Load = @Sendable (URL) async throws -> any ModelEngine

    private let check: Check
    private let load: Load
    private let clearMemory: @Sendable () async -> Void
    private let folder: URL
    private var loading: Task<any ModelEngine, any Error>?

    /// Whether the last call loaded the model, and how long the check and the load took (for the self-test).
    enum LoadNote: Equatable, Sendable {
        case loaded(seconds: Double)
        case alreadyLoaded

        var words: String {
            switch self {
            case .loaded(let seconds):
                "Model loaded for this test in \(seconds.formatted(.number.precision(.fractionLength(1)))) s"
            case .alreadyLoaded: "Model was already loaded"
            }
        }
    }

    private(set) var lastLoad: LoadNote?

    init(check: @escaping Check, load: @escaping Load, clearMemory: @escaping @Sendable () async -> Void,
         folder: URL) {
        (self.check, self.load, self.clearMemory, self.folder) = (check, load, clearMemory, folder)
    }

    var isLoaded: Bool { loading != nil }

    func generate(_ request: ModelRequest) async throws -> String {
        let engine = try await loaded()
        do {
            let answer = try await engine.generate(request)
            await clearMemory()  // done before the answer goes back, success or not
            return answer
        } catch {
            await clearMemory()
            throw error
        }
    }

    func release() async {
        loading?.cancel()
        loading = nil
        await clearMemory()
    }

    private func loaded() async throws -> any ModelEngine {
        if let loading {
            lastLoad = .alreadyLoaded
            return try await loading.value
        }
        let start = ContinuousClock.now
        let (check, load, folder) = (check, load, folder)
        let task = Task<any ModelEngine, any Error> {
            switch await check() {
            case .verified: break
            case .notInThisBuild: throw ModelUnavailable.notInThisBuild
            case .refused: throw ModelUnavailable.failedCheck
            }
            do { return try await load(folder) } catch { throw ModelUnavailable.couldNotLoad }
        }
        loading = task
        do {
            let engine = try await task.value
            let took = ContinuousClock.now - start
            lastLoad = .loaded(seconds: Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18)
            return engine
        } catch {
            if loading == task { loading = nil }  // try again next time
            throw error
        }
    }
}

/// Releases the model when the app goes to the background or iOS warns about memory (Apple: respond to
/// low-memory warnings; checked Nov 6). The center is injected so tests post the events themselves.
@MainActor
final class ModelMemoryWatcher {
    static let background = UIApplication.didEnterBackgroundNotification
    static let memoryWarning = UIApplication.didReceiveMemoryWarningNotification

    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    init(host: ModelHost, center: NotificationCenter = .default) {
        self.center = center
        observers = [Self.background, Self.memoryWarning].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { await host.release() }
            }
        }
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
