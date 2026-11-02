import Foundation

/// Tells the officer, in plain words, which missions the lease check destroyed and why (ADR 0012).
enum ShreddedNotice {
    static func text(for records: [ShredRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        let order: [ShredRecord.Reason] = [.leaseEnded, .clockMovedBack, .shredOrder, .officer]
        return order.compactMap { reason -> String? in
            let missions = records.filter { $0.reason == reason }.map(\.mission)
            guard !missions.isEmpty else { return nil }
            let count = missions.count == 1 ? "1 mission was" : "\(missions.count) missions were"
            return "\(count) destroyed on this iPhone because \(why(reason)): \(missions.joined(separator: ", "))."
        }.joined(separator: " ")
    }

    private static func why(_ reason: ShredRecord.Reason) -> String {
        switch reason {
        case .leaseEnded: "\(KeyLease.defaultDays) days passed without a sync"
        case .clockMovedBack: "its clock was set back"
        case .shredOrder: "your organization sent a shred order"
        case .officer: "you destroyed it"
        }
    }
}
