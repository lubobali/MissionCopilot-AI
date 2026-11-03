#if DEBUG
import Foundation
import Observation
import UIKit

/// The lock test of the phone proof (#74), Debug only. The screen calls `tick` every half second while
/// the officer locks the phone and unlocks it again. The store must pause (writes refused, so no lock is
/// held when iOS suspends the app: no 0xDEAD10CC), the database file must be unreadable while locked,
/// and after unlock writes resume with every confirmed note still there.
@MainActor @Observable
final class StoreLockTest {
    struct Event: Codable, Equatable, Sendable {
        let second: Double
        let what: String
    }

    /// What the run saved for the Mac.
    struct Results: Codable, Equatable, Sendable {
        let written: Int
        let refused: Int
        let events: [Event]
        let checks: [StoreProofReport.Check]
    }

    static let mission = "kandor-lock"
    static let checkNames = ["lock pause", "unreadable while locked", "data intact", "audit log"]
    static let resultsFile = "lock-results.json"
    /// Left in the outbox while a run is going: still there at the next launch means iOS killed the app.
    static let runningFile = "lock-test-running"

    private static let signals: [(Notification.Name, String)] = [
        (UIApplication.didEnterBackgroundNotification, "app left the screen"),
        (UIApplication.protectedDataWillBecomeUnavailableNotification, "protected data going away"),
        (UIApplication.protectedDataDidBecomeAvailableNotification, "protected data back"),
        (UIApplication.willEnterForegroundNotification, "app back on screen")
    ]

    private(set) var written = 0
    private(set) var refused = 0
    private(set) var events: [Event] = []

    private let missions: MissionStore
    private let outbox: URL
    private let fileIsReadable: () -> Bool
    private let start = Date()
    private let notesBefore: Int
    private var paused = false
    private var sawUnreadableFile = false
    private var otherErrors: [String] = []
    private var center: NotificationCenter?
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - signals: where the phone's lock signals arrive (the app passes `.default`), recorded as events.
    ///   - fileIsReadable: tries to read the database file itself, as anything on the phone would.
    init(missions: MissionStore, outbox: URL, signals: NotificationCenter,
         fileIsReadable: @escaping () -> Bool) throws {
        self.missions = missions
        self.outbox = outbox
        self.fileIsReadable = fileIsReadable
        if try !missions.missionIDs().contains(Self.mission) {
            try missions.create(mission: Self.mission, title: "Kandor lock test")
        }
        notesBefore = try missions.notes(in: Self.mission).count
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        try Data().write(to: outbox.appendingPathComponent(Self.runningFile))
        center = signals
        observers = Self.signals.map { name, what in
            signals.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.record(what) }
            }
        }
    }

    static func unfinished(in outbox: URL) -> Bool {
        FileManager.default.fileExists(atPath: outbox.appendingPathComponent(runningFile).path)
    }

    /// One write attempt; a refusal while locked also tries to read the database file.
    func tick() {
        do {
            try missions.addNote("lock test \(notesBefore + written + 1)", to: Self.mission)
            written += 1
            if paused {
                paused = false
                record("writes resumed")
            }
        } catch EncryptedStore.Failure.suspended {
            refused += 1
            if !paused {
                paused = true
                record("writes paused")
            }
            if !sawUnreadableFile, !fileIsReadable() {
                sawUnreadableFile = true
                record("database file unreadable")
            }
        } catch {
            otherErrors.append("\(error)")
        }
    }

    /// Stops listening, checks the run, saves the results and clears the running marker.
    func finish() -> [StoreProofReport.Check] {
        observers.forEach { center?.removeObserver($0) }
        observers = []
        var checks = [
            StoreProofReport.Check(name: "lock pause", passed: refused > 0 && !paused,
                                   detail: "\(written) written, \(refused) refused while locked, resumed: \(!paused)"),
            StoreProofReport.Check(name: "unreadable while locked", passed: sawUnreadableFile,
                                   detail: "database file unreadable while locked: \(sawUnreadableFile)")
        ]
        let count = Result { try missions.notes(in: Self.mission).count }
        let intact = (try? count.get()) == notesBefore + written && otherErrors.isEmpty
        checks.append(StoreProofReport.Check(name: "data intact", passed: intact, detail: "notes after: "
            + "\((try? count.get()).map(String.init) ?? "unreadable"), expected \(notesBefore + written), "
            + "other errors: \(otherErrors.isEmpty ? "none" : otherErrors.joined(separator: "; "))"))
        let audit = Result { try missions.store.verifyAudit() }
        let auditValid = if case .success(.valid) = audit { true } else { false }
        checks.append(StoreProofReport.Check(name: "audit log", passed: auditValid, detail: "\(audit)"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let results = Results(written: written, refused: refused, events: events, checks: checks)
        try? encoder.encode(results).write(to: outbox.appendingPathComponent(Self.resultsFile))
        try? FileManager.default.removeItem(at: outbox.appendingPathComponent(Self.runningFile))
        return checks
    }

    private func record(_ what: String) {
        events.append(Event(second: (Date().timeIntervalSince(start) * 10).rounded() / 10, what: what))
    }
}
#endif
