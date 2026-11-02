import Foundation
import Security

/// When the app must ask for Face ID or the passcode (ADR 0012 decision 5). Cold start always asks;
/// coming back asks once the grace time has passed. A clock that moved backwards while away also asks:
/// when in doubt, lock. The screen and the database open only after the Keychain releases the data key.
struct AppLockPolicy: Equatable, Sendable {
    static let defaultGraceMinutes = 2
    static let maxGraceMinutes = 5

    let graceMinutes: Int

    init(graceMinutes: Int = AppLockPolicy.defaultGraceMinutes) {
        self.graceMinutes = min(max(graceMinutes, 0), Self.maxGraceMinutes)
    }

    /// - Parameter leftAt: when the app last went to the background, or nil if it never left.
    func mustAsk(coldStart: Bool, leftAt: Date?, now: Date) -> Bool {
        if coldStart { return true }
        guard let leftAt else { return false }
        let away = now.timeIntervalSince(leftAt)
        return away < 0 || away >= TimeInterval(graceMinutes * 60)
    }
}

/// How the database key is kept: released only after Face ID or the passcode (user presence), and only
/// while this phone has a passcode, never synced or restored to another phone. Removing the passcode
/// deletes the item, so a phone without a passcode cannot open mission data. Built into the encrypted
/// store in Phase 4; iOS cannot report these back from an item, so a test pins them.
enum DataKeyAccess {
    static var accessibility: CFString { kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
    static let flags: SecAccessControlCreateFlags = .userPresence

    struct Failed: Error {}

    static func make() throws -> SecAccessControl {
        guard let access = SecAccessControlCreateWithFlags(nil, accessibility, flags, nil) else { throw Failed() }
        return access
    }
}
