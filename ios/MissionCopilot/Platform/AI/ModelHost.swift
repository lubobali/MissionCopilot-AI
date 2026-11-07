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
        if let loading { return try await loading.value }
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
            return try await task.value
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
