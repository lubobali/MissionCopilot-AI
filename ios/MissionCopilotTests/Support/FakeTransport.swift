import Foundation
@testable import MissionCopilot

/// A network that answers from a script and remembers every request, for ServerClient tests.
final class FakeTransport: Transport, @unchecked Sendable {
    struct Answer {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    private let lock = NSLock()
    private var answers: [Result<Answer, URLError>]
    private(set) var sent: [URLRequest] = []

    init(_ answers: [Result<Answer, URLError>]) { self.answers = answers }

    convenience init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.init(Array(repeating: .success(Answer(status: status, headers: headers, body: body)), count: 20))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer: Result<Answer, URLError> = lock.withLock {
            sent.append(request)
            return answers.removeFirst()
        }
        let found = try answer.get()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: found.status, httpVersion: nil,
                                             headerFields: found.headers) else { throw URLError(.badURL) }
        return (found.body, response)
    }
}
