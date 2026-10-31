import CryptoKit
import EncryptionLab
import Foundation
import Observation
import UIKit

/// Spike #16 proofs on the iPhone. Debug lab only; production code is rebuilt test-first in Phase 3.
@MainActor @Observable
final class EncryptionLabModel {
    struct MissionStatus: Identifiable {
        let id: String
        let text: String
    }

    private(set) var log: [String] = ["Start with 1. Set up."]
    private(set) var missions: [MissionStatus] = []
    private(set) var running = false

    private let user = "amina"
    private let keyStore = KeychainKeyStore()
    private let vault = SecureEnclaveKeyVault()
    private var store: MissionStore?
    private var folder: URL?
    private var results: [String: String] = [:]
    private var pendingSave = false

    private var databaseURL: URL? { folder?.appendingPathComponent("user.sqlite") }
    private var plainTwinURL: URL { DeviceInfo.documents.appendingPathComponent("plain-twin.sqlite") }

    /// Reopens existing data when the screen appears, so leaving and coming back keeps the missions.
    func reopenIfSetUp() {
        guard store == nil, let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
            FileManager.default.fileExists(atPath: base.appendingPathComponent(user).path) else { return }
        setUp()
    }

    func setUp() {
        step("setup") {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            let folder = try ProtectedDirectory.create(for: user, in: base)
            let pool = try EncryptedDatabase.open(at: folder.appendingPathComponent("user.sqlite").path,
                                                  key: keyStore.loadOrCreate(for: user))
            let store = try MissionStore(db: pool, vault: vault)
            if try store.missionIDs().isEmpty {
                try store.createMission(id: "kandor-roads", title: "Kandor rural roads")
                try store.addNote("Km 42 culvert washed out", to: "kandor-roads")
                try store.createMission(id: "kandor-bridges", title: "Kandor bridges")
                try store.addNote("Bridge 3 deck cracked", to: "kandor-bridges")
            }
            self.folder = folder
            self.store = store
            try writePlainTwin()
            record("cipher_version", try EncryptedDatabase.cipherVersion())
            record("secure_enclave_available", "\(SecureEnclaveKeyVault.isAvailable)")
            refresh()
        }
    }

    func wrongKey() {
        step("wrong_key") {
            guard let path = databaseURL?.path else { return log("Run 1. Set up first.") }
            do {
                _ = try EncryptedDatabase.open(at: path, key: DatabaseKey.random())
                record("wrong_key", "OPENED, FAIL")
            } catch {
                record("wrong_key", "rejected: \(error)")
            }
        }
    }

    func protectionReport() {
        step("protection") {
            guard let folder else { return log("Run 1. Set up first.") }
            for entry in try ProtectedDirectory.report(folder) {
                record("protection \(entry.name)", entry.protection?.rawValue ?? "none")
            }
            let backup = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            record("folder excluded from backup", "\(backup ?? false)")
        }
    }

    func shred(_ mission: String) {
        step("shred") {
            try store?.shred(mission: mission)
            record("shred \(mission)", "chip key deleted, \(try store?.sealedNoteCount(in: mission) ?? 0) sealed notes left")
            refresh()
        }
    }

    /// Lock the phone right after tapping. The checks run the moment iOS locks the data (about 10 s after
    /// the side button), not after a guessed delay, and the timeline is recorded with the results.
    func lockTest() {
        guard let store, let databaseURL else { return log("Run 1. Set up first.") }
        let probe: WrappedMissionKey
        do {
            try vault.destroy(mission: "lock-probe")  // left over from the last run (cannot delete while locked)
            probe = try vault.wrap(SymmetricKey(size: .bits256), for: "lock-probe")
        } catch {
            return log("lock test FAILED to start: \(error)")
        }
        for key in results.keys where key.hasPrefix("lock:") { results[key] = nil }
        running = true
        log("Lock the phone NOW (side button), face down. Wait 30 s, then unlock.")
        // iOS gives about 30 s in the background once locked: save before that, or the app is killed first.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "lock-test") {
            UIApplication.shared.endBackgroundTask(task)
        }
        let start = Date()
        Task {
            while UIApplication.shared.isProtectedDataAvailable, Date().timeIntervalSince(start) < 45 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            let seconds = String(format: "%.1f s after tap", Date().timeIntervalSince(start))
            if UIApplication.shared.isProtectedDataAvailable {
                record("lock: test valid", "NO, data still unlocked \(seconds) (app may have been paused); run it again")
            } else {
                record("lock: test valid", "yes, data locked \(seconds)")
                check("lock: raw database file") { _ = try Data(contentsOf: databaseURL) }
                check("lock: database key in Keychain") { _ = try self.keyStore.loadOrCreate(for: self.user) }
                check("lock: chip unwrap") { _ = try self.vault.unwrap(probe, for: "lock-probe") }
                check("lock: database read") { _ = try store.missionIDs() }
            }
            save()
            running = false
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    func speedTest() {
        step("speed") {
            for key in results.keys where key.hasPrefix("speed:") { results[key] = nil }
            guard let folder else { return log("Run 1. Set up first.") }
            // 5 rounds, order swapped each round so warm-up does not favour one side; report the median.
            var plain: [Double] = []
            var cipher: [Double] = []
            for round in 0..<5 {
                let plainPath = folder.appendingPathComponent("speed-plain.sqlite").path
                let cipherPath = folder.appendingPathComponent("speed-cipher.sqlite").path
                let runPlain = {
                    plain.append(try SpeedTest.insertMilliseconds(
                        into: EncryptedDatabase.openUnencrypted(at: plainPath), rows: 5000))
                }
                let runCipher = {
                    cipher.append(try SpeedTest.insertMilliseconds(
                        into: EncryptedDatabase.open(at: cipherPath, key: DatabaseKey.random()), rows: 5000))
                }
                if round.isMultiple(of: 2) { try runPlain(); try runCipher() } else { try runCipher(); try runPlain() }
                for path in [plainPath, cipherPath] { removeDatabase(at: path) }
            }
            record("speed: 5000 inserts plain ms (median of 5)", String(format: "%.1f", median(plain)))
            record("speed: 5000 inserts SQLCipher ms (median of 5)", String(format: "%.1f", median(cipher)))
            record("speed: all rounds plain / SQLCipher", plain.map { String(format: "%.0f", $0) }.joined(separator: ",")
                   + " / " + cipher.map { String(format: "%.0f", $0) }.joined(separator: ","))
            let chip = try SpeedTest.unwrapMilliseconds(vault: vault, mission: "speed-probe", runs: 20)
            let soft = try SpeedTest.unwrapMilliseconds(vault: SoftwareKeyVault(), mission: "speed-probe", runs: 20)
            record("speed: chip unwrap avg ms", String(format: "%.2f", chip))
            record("speed: software unwrap avg ms", String(format: "%.2f", soft))
        }
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    func resetAll() {
        step("reset") {
            for mission in (try store?.missionIDs()) ?? [] {
                try store?.shred(mission: mission)
                try store?.purge(mission: mission)
            }
            store = nil
            try keyStore.delete(for: user)
            if let folder { try FileManager.default.removeItem(at: folder) }
            removeDatabase(at: plainTwinURL.path)
            folder = nil
            missions = []
            results = [:]
            log = ["Reset done. Start with 1. Set up."]
        }
    }

    // MARK: - Helpers

    /// Same schema and title, no SQLCipher: the "before" file for the outside check.
    private func writePlainTwin() throws {
        removeDatabase(at: plainTwinURL.path)
        let twin = try MissionStore(db: EncryptedDatabase.openUnencrypted(at: plainTwinURL.path), vault: SoftwareKeyVault())
        try twin.createMission(id: "kandor-roads", title: "Kandor rural roads")
    }

    private func refresh() {
        guard let store else { return }
        missions = ((try? store.missionIDs()) ?? []).map { id in
            do {
                return MissionStatus(id: id, text: "Readable: \(try store.notes(in: id).joined(separator: "; "))")
            } catch is MissionKeyNotFound {
                return MissionStatus(id: id, text: "Cannot be read (shredded)")
            } catch {
                return MissionStatus(id: id, text: "Error: \(error)")
            }
        }
    }

    private func check(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            record(name, "READABLE, FAIL")
        } catch {
            record(name, "blocked: \(error)")
        }
    }

    private func step(_ name: String, _ body: () throws -> Void) {
        do { try body() } catch { log("\(name) FAILED: \(error)") }
        save()
    }

    private func record(_ name: String, _ value: String) {
        results[name] = value
        log("\(name): \(value)")
    }

    private func log(_ line: String) { log.append(line) }

    private func removeDatabase(at path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func save() {
        guard !results.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = DeviceInfo.documents.appendingPathComponent("encryption-results.json")
        do {
            try encoder.encode(results).write(to: url)
            pendingSave = false
        } catch {
            // Expected while locked: Complete protection blocks writes too, even for this app's own files.
            pendingSave = true
            log("save waits for unlock: \(error)")
        }
    }

    /// Called when the app is active again after the lock test.
    func saveIfPending() {
        if pendingSave { save() }
    }
}
