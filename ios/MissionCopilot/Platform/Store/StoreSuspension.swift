import Foundation
import GRDB
import UIKit

/// Pauses the store before iOS takes its files away, and resumes it after (#69). About 10 seconds after
/// the phone locks, Complete files become unreadable, and an app that holds a database lock while
/// suspended is killed (0xDEAD10CC). GRDB's suspension makes a paused store refuse new locks instead.
final class StoreSuspension {
    private static let pause: [Notification.Name] = [
        UIApplication.protectedDataWillBecomeUnavailableNotification, UIApplication.didEnterBackgroundNotification
    ]
    private static let resume: [Notification.Name] = [
        UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.willEnterForegroundNotification
    ]

    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    /// - Parameter center: where the phone's signals arrive (the app passes `.default`; tests their own).
    init(observing center: NotificationCenter) {
        self.center = center
        observers = Self.pause.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
            }
        } + Self.resume.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
            }
        }
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers = []
    }

    deinit { stop() }
}
