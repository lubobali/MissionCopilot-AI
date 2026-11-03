import Foundation

/// The number every signed request carries (docs/security.md, #90). The server takes a request only if
/// its number is above the last one it took, so this number must always rise and survive a restart.
/// It is kept in the Keychain (this device only, while unlocked) and is never below the clock in
/// milliseconds: even if the stored counter were lost, the next number is still above every number sent
/// before (unless the clock is also set back). An actor, so two requests never get the same number.
actor RequestCounter {
    private let items: KeychainItems
    private let account: String
    private let now: @Sendable () -> Date

    init(items: KeychainItems, account: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.items = items
        self.account = account
        self.now = now
    }

    func next() throws -> Int {
        let stored = try items.load(account).flatMap { String(bytes: $0, encoding: .utf8) }.flatMap { Int($0) }
        let clock = Int((now().timeIntervalSince1970 * 1000).rounded(.down))
        let number = max((stored ?? 0) + 1, clock)
        let data = Data(String(number).utf8)
        let updated = try stored != nil && items.update(data, account: account)
        if !updated {
            guard try items.add(data, account: account, access: ChipKeyAccess.blob()) else {
                throw KeychainFailure(status: errSecDuplicateItem)
            }
        }
        return number
    }
}
