import Foundation

/// How long the phone waits before it tries a busy server again (#104). The server's own Retry-After when it
/// gives one; otherwise a random wait under a cap that doubles with each try ("full jitter", AWS Architecture
/// Blog, Exponential Backoff And Jitter), so phones that lost the server together do not all come back at the
/// same second. Every wait is kept between 5 seconds and 5 minutes, and a run of tries ends after `maxTries`:
/// then the person decides.
enum Backoff {
    static let maxTries = 5
    static let shortest = 5
    static let longest = 300

    /// `attempt` counts from 0; `jitter(cap)` gives a random whole number from 0 to cap.
    static func delay(asked: Int?, attempt: Int, jitter: (Int) -> Int) -> Int {
        if let asked { return kept(asked) }
        // 5 << 6 is already past the longest wait; shifting further would wrap to 0.
        let cap = attempt >= 6 ? longest : min(longest, shortest << max(attempt, 0))
        return kept(jitter(cap))
    }

    private static func kept(_ seconds: Int) -> Int { min(longest, max(shortest, seconds)) }

    /// Retry-After (RFC 9110 10.2.3): whole seconds, or an HTTP date (IMF-fixdate); nil when it is neither.
    static func retryAfter(_ value: String?, now: Date) -> Int? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) { return Int(text) }
        guard let date = httpDate.date(from: text) else { return nil }
        return max(0, Int(date.timeIntervalSince(now).rounded()))
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
}
