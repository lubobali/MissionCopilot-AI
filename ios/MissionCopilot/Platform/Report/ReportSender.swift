import Foundation

/// Sends the approved report (#173, step 8.3.2; ADR 0006): the Face ID approval key first (#171), then the batch
/// with the outbox's one Idempotency-Key, then each evidence file behind the cited facts, once. The receipt and
/// each confirmed file are kept, so a try after a lost signal sends only what is missing, as the same batch.
struct ReportSender: Sendable {
    enum Outcome: Equatable, Sendable { case received(Date), waiting, refused(String), failed, notQueued }

    static let refusedWords = "The server did not take this report. It does not match its approval or its evidence."

    let store: MissionStore
    let registration: ApprovalKeyRegistration

    private struct Receipt: Decodable { let batchId: String, receivedAt: String }

    func send(mission: String, client: ServerClient) async -> Outcome {
        guard let queued = try? store.outbox(in: mission),
              let batch = try? SyncBatchBuilder.build(in: mission, store: store) else { return .notQueued }
        var receipt = try? store.receipt(in: mission)
        if receipt == nil {
            guard await registration.ensure(client: client) != .notYet else { return .waiting }
            let answer = await client.post("/v1/missions/\(mission)/sync", body: batch.body,
                                           headers: ["Idempotency-Key": queued.idempotencyKey])
            switch Self.received(answer) {
            case .success(let kept):
                try? store.keepReceipt(batchId: kept.batchId, receivedAt: kept.receivedAt, in: mission)
                receipt = kept
            case .failure(let problem): return problem.outcome
            }
        }
        guard let receipt else { return .failed }
        let sent = Set((try? store.filesSent(in: mission)) ?? [])
        for seq in batch.files where !sent.contains(seq) {
            guard let data = try? store.evidenceFile(in: mission, seq: seq) else { return .failed }
            let answer = await client.post("/v1/missions/\(mission)/evidence/\(seq)/file", body: data,
                                           contentType: "application/octet-stream")
            guard case .success = answer else { return Self.problem(answer) }
            try? store.keepFileSent(seq: seq, in: mission)
        }
        return .received(receipt.receivedAt)
    }

    private static func received(_ answer: ServerClient.Outcome) -> Result<ReportReceipt, NotReceivedOutcome> {
        guard case .success(let data, _, _) = answer else { return .failure(NotReceivedOutcome(problem(answer))) }
        guard let kept = try? JSONDecoder().decode(Receipt.self, from: data),
              let when = ISO8601DateFormatter().date(from: kept.receivedAt) else {
            return .failure(NotReceivedOutcome(.failed))
        }
        return .success(ReportReceipt(batchId: kept.batchId, receivedAt: when))
    }

    /// Offline, busy or locked: wait and try again; refused by the checks: say so; anything else failed.
    private static func problem(_ answer: ServerClient.Outcome) -> Outcome {
        switch answer {
        case .offline, .busy, .slowDown, .phoneLocked: .waiting
        case .failed(409), .failed(422): .refused(refusedWords)
        default: .failed
        }
    }
}

/// An outcome that is not a receipt, carried through `Result`.
struct NotReceivedOutcome: Error, Equatable {
    let outcome: ReportSender.Outcome
    init(_ outcome: ReportSender.Outcome) { self.outcome = outcome }
}
