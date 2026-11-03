import Foundation
import Testing
import UIKit
@testable import MissionCopilot

/// About 10 seconds after the phone locks, Complete files become unreadable, and an app holding a
/// database lock while suspended is killed (0xDEAD10CC). The store pauses when protected data goes away
/// or the app leaves the screen, and resumes when it comes back (#69). The phone run (#74) proves it.
@Suite(.serialized, .takesTurnsWithThePause)
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

    /// GRDB pauses writes only. A read while locked still maps the -shm file, which iOS has made
    /// unreadable, and the app is killed (SIGBUS, found by the iPhone lock test, #74).
    @Test(arguments: [UIApplication.protectedDataWillBecomeUnavailableNotification,
                      UIApplication.didEnterBackgroundNotification])
    func thePausedStoreRefusesReadsToo(signal: Notification.Name) throws {
        let center = NotificationCenter()
        let store = try store()
        try store.setInfo("site", "Kandor")
        let suspension = StoreSuspension(observing: center)
        defer { center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil) }

        center.post(name: signal, object: nil)

        #expect(throws: EncryptedStore.Failure.suspended) { try store.info("site") }
        #expect(throws: EncryptedStore.Failure.suspended) { try store.verifyAudit() }
        _ = suspension
    }

    @Test func aPausedMissionStoreRefusesTheReadBeforeANote() throws {
        let center = NotificationCenter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let keys = KeychainDataKeyStore(service: "missioncopilot.tests.\(UUID().uuidString)",
                                        access: DataKeyStoreTests.plainAccess)
        defer { try? keys.delete(for: "reader") }
        let missions = try UserStore.openMissions(user: "reader", in: root, keys: keys,
                                                  vault: SoftwareKeyVault()).missions
        try missions.create(mission: "kandor-roads", title: "Kandor roads")
        let suspension = StoreSuspension(observing: center)
        defer { center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil) }

        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)

        #expect(throws: EncryptedStore.Failure.suspended) { try missions.notes(in: "kandor-roads") }
        #expect(throws: EncryptedStore.Failure.suspended) { try missions.addNote("km 42", to: "kandor-roads") }
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
        #expect(try store.info("site") == "Kandor")
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
