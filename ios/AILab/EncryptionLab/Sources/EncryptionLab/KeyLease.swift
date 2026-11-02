import Foundation

/// ADR 0012: a mission key works offline only for its lease, which every sync renews. The phone's clock
/// is trusted only forward: set back by more than 5 minutes from the last time the app saw, the lease
/// ends (moving it forward can only end it sooner).
public struct KeyLease: Codable, Equatable, Sendable {
    public enum Ended: String, Codable, Sendable { case expired, clockMovedBack }

    public enum State: Equatable, Sendable {
        case valid(daysLeft: Int)
        case ended(Ended)
    }

    public static let defaultDays = 14
    public static let maxDays = 30
    static let clockTolerance: TimeInterval = 300
    static let day: TimeInterval = 86_400

    public let mission: String
    public let renewedAt: Date
    public let days: Int

    public init(mission: String, renewedAt: Date, days: Int = KeyLease.defaultDays) {
        self.mission = mission
        self.renewedAt = renewedAt
        self.days = min(max(days, 1), Self.maxDays)
    }

    public var endsAt: Date { renewedAt.addingTimeInterval(TimeInterval(days) * Self.day) }

    public func state(now: Date, lastSeen: Date) -> State {
        if now < lastSeen.addingTimeInterval(-Self.clockTolerance) { return .ended(.clockMovedBack) }
        let left = endsAt.timeIntervalSince(now)
        return left > 0 ? .valid(daysLeft: Int((left / Self.day).rounded(.up))) : .ended(.expired)
    }

    public func renewed(at sync: Date) -> KeyLease { KeyLease(mission: mission, renewedAt: sync, days: days) }

    /// The latest time the app has seen; kept with the leases so a clock set back is noticed.
    public static func lastSeen(previous: Date, now: Date) -> Date { max(previous, now) }
}
