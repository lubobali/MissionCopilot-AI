import Foundation

/// Sending from the report page (#173, step 8.3.3; ADR 0006): only an approved report; the review says exactly
/// what goes; Send queues it (one stable key) and says what happened; a page opened later shows the receipt, or
/// that it waits for a connection (queued reports also go by themselves after the next mission-list answer).
extension ReportModel {
    /// What the batch holds, for the review; nil until the report is approved.
    var sendCounts: SyncBatch.Counts? {
        guard approved != nil else { return nil }
        return try? SyncBatchBuilder.build(in: mission, store: store).counts
    }

    var sendReview: String {
        guard let counts = sendCounts else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(counts.bytes), countStyle: .file)
        return "\(counts.sentences) sentences, \(counts.facts) facts, \(counts.evidence) signed evidence items "
            + "and \(counts.files) files (photos, pages, recordings), the report \(size). Signed with Face ID; "
            + "nothing else leaves this iPhone."
    }

    var sendWords: String {
        switch sendOutcome {
        case .received(let when): "Received by the server \(when.formatted(date: .abbreviated, time: .shortened))."
        case .waiting: "Waiting for a connection. It goes by itself when this iPhone is online."
        case .refused(let words): words
        case .failed: "The report could not be sent. Try again."
        case .notQueued: "Connect this iPhone to the server first."
        case nil: ""
        }
    }

    func send() async {
        guard approved != nil, let sendReport, (try? store.queueReport(in: mission)) != nil else { return }
        sending = true
        sendOutcome = await sendReport(mission)
        sending = false
    }

    /// On opening: the receipt if the server confirmed it, waiting if it is queued, else nothing yet.
    func sentBefore() -> ReportSender.Outcome? {
        if let receipt = try? store.receipt(in: mission) { return .received(receipt.receivedAt) }
        return (try? store.outbox(in: mission)) != nil ? .waiting : nil
    }
}
