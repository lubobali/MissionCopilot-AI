import Foundation

/// The phone learns the manager's decision (#193, step 193.2; server #178): after each mission-list answer,
/// for each report received and not yet decided, it asks the server once. A decision on the version it sent is
/// kept (a send back opens the next version); none yet (404), offline or anything else changes nothing.
struct ReportReviewReader: Sendable {
    let store: MissionStore

    private struct Answer: Decodable {
        let version: Int
        let decision: String
        let note: String?
        let reviewedAt: String
    }

    /// The decision kept now, if any.
    @discardableResult
    func read(mission: String, client: ServerClient) async -> ReportReview? {
        guard case .success(let data, _, _) = await client.get("/v1/missions/\(mission)/report/review"),
              let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let decision = ReportReview.Decision(rawValue: answer.decision),
              let when = ISO8601DateFormatter().date(from: answer.reviewedAt) else { return nil }
        let review = ReportReview(version: answer.version, decision: decision,
                                  note: answer.note.flatMap { $0.isEmpty ? nil : $0 }, reviewedAt: when)
        return (try? store.keepReview(review, in: mission)) == true ? review : nil
    }

    /// Every report waiting for its decision.
    func readAll(client: ServerClient) async {
        for mission in (try? store.awaitingReview()) ?? [] {
            await read(mission: mission, client: client)
        }
    }
}
