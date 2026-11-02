import Foundation
import Testing
import UIKit
@testable import MissionCopilot

/// About 10 seconds after the phone locks, Complete files become unreadable, and an app holding a
/// database lock while suspended is killed (0xDEAD10CC). The store pauses when protected data goes away
/// or the app leaves the screen, and resumes when it comes back (#69). The phone run (#74) proves it.
@Suite(.serialized)
struct StoreSuspensionTests {
    private func store(suspendable: Bool = true) throws -> EncryptedStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        return try EncryptedStore.open(at: file, key: DataKey.random(), suspendable: suspendable)
    }

    @Test(arguments: [UIApplication.protectedDataWillBecomeUnavailableNotification,
                      UIApplication.didEnterBackgroundNotification])
    func theStorePausesAndWritesFailCleanly(signal: Notification.Name) throws {
        let center = NotificationCenter()
        let store = try store()
        let suspension = StoreSuspension(observing: center)
        defer { center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil) }

        center.post(name: signal, object: nil)

        #expect(throws: EncryptedStore.Failure.suspended) { try store.setInfo("site", "Kandor") }
        _ = suspension
    }

    @Test(arguments: [UIApplication.protectedDataDidBecomeAvailableNotification,
                      UIApplication.willEnterForegroundNotification])
    func theStoreResumesWithItsDataIntact(signal: Notification.Name) throws {
        let center = NotificationCenter()
        let store = try store()
        try store.setInfo("site", "Kandor")
        let suspension = StoreSuspension(observing: center)
        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)

        center.post(name: signal, object: nil)

        try store.setInfo("km", "42")
        #expect(try store.info("site") == "Kandor")
        _ = suspension
    }

    @Test func aStoreThatIsNotSuspendableIsNotAffected() throws {
        let center = NotificationCenter()
        let store = try store(suspendable: false)
        let suspension = StoreSuspension(observing: center)
        defer { center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil) }

        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)

        try store.setInfo("site", "Kandor")
        _ = suspension
    }

    @Test func afterStoppingTheSignalsChangeNothing() throws {
        let center = NotificationCenter()
        let store = try store()
        StoreSuspension(observing: center).stop()

        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)

        try store.setInfo("site", "Kandor")
    }
}
