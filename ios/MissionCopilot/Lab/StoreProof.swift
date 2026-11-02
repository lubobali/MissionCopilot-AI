#if DEBUG
import Foundation
import LocalAuthentication

/// What one proof run found, saved as results.json for the Mac (#74).
struct StoreProofReport: Codable, Equatable, Sendable {
    struct Check: Codable, Equatable, Sendable {
        let name: String
        let passed: Bool
        let detail: String
    }

    let date: String
    let device: String
    let checks: [Check]

    var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
}

/// The phone proof of the Phase 4 store (#74), Debug only. It runs the real store code (the user's
/// protected folder and Keychain key, the chip vault and signer, leases, the audit log) on its own
/// folder, keys and profile, so the officer's real store is never touched. Every run starts fresh.
struct StoreProof {
    static let user = "store-proof"
    /// Fictional text put in every sealed field and the mission title: it must never appear on disk.
    static let marker = "KANDOR-PROOF-MARKER-7Q"
    static let dataKeyService = "com.lubobali.missioncopilot.proof.datakey"
    static let vaultService = "com.lubobali.missioncopilot.proof.missionkey"
    static let signerService = "com.lubobali.missioncopilot.proof.evidencekey"
    static let checkNames = [
        "encrypted store", "file protection", "evidence chain", "trace", "sealed rows",
        "lease ended", "shred order", "audit log", "export"
    ]
    static let chainFile = "evidence-chain.json"
    static let resultsFile = "results.json"

    private static let mission = "kandor-roads"
    /// Created with a lease that ended a day ago: the next open must shred it.
    private static let oldMission = "kandor-old"

    let base: URL
    /// Files for the Mac (Documents, seen in Finder): the chain, the database copy, the results.
    let outbox: URL
    let keys: KeychainDataKeyStore
    let vault: any MissionKeyVault
    let signer: any EvidenceSigner

    static func live() -> StoreProof {
        StoreProof(base: URL.applicationSupportDirectory.appendingPathComponent("StoreProof", isDirectory: true),
                   outbox: URL.documentsDirectory.appendingPathComponent("store-proof", isDirectory: true),
                   keys: KeychainDataKeyStore(service: dataKeyService),
                   vault: SecureEnclaveVault(service: vaultService),
                   signer: SecureEnclaveEvidenceSigner(user: user, service: signerService))
    }

    /// - Parameter context: the Face ID that just succeeded, so the data key opens without a second prompt.
    func run(context: LAContext? = nil, now: Date = Date(), device: String = "") -> StoreProofReport {
        cleanUp()
        var checks = Checks()
        fillAndCheck(context: context, now: now, into: &checks)
        reopenAndShred(context: context, now: now, into: &checks)  // the first store is closed by now
        checks.add("export") {
            try copyDatabase()
            let names = try FileManager.default.contentsOfDirectory(atPath: outbox.path)
            let ready = names.contains(Self.chainFile) && names.contains(UserStore.fileName)
            return (ready, names.sorted().joined(separator: ", "))
        }
        let report = StoreProofReport(date: EvidenceChain.timestamp(now), device: device, checks: checks.list)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(report).write(to: outbox.appendingPathComponent(Self.resultsFile))
        return report
    }

    /// Removes everything an earlier run left: folders, the data key, the mission keys.
    func cleanUp() {
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.removeItem(at: outbox)
        try? keys.delete(for: Self.user)
        for mission in [Self.mission, Self.oldMission] { try? vault.destroy(mission: mission) }
    }

    private var folder: URL { base.appendingPathComponent(Self.user, isDirectory: true) }

    private func fillAndCheck(context: LAContext?, now: Date, into checks: inout Checks) {
        let opened = Result { try UserStore.openMissions(user: Self.user, in: base, keys: keys, vault: vault,
                                                         context: context, now: now) }
        let sentence = opened.flatMap { opened in Result { try fill(opened.missions, now: now) } }
        checks.add("encrypted store") {
            let store = try opened.get().missions.store
            let cipher = try store.readerCipherVersion()
            let wrongKey = Result { try EncryptedStore.open(at: folder.appendingPathComponent(UserStore.fileName),
                                                            key: DataKey.random()) }
            let refused = if case .failure(EncryptedStore.Failure.wrongKey) = wrongKey { true } else { false }
            return (!cipher.isEmpty && refused, "SQLCipher \(cipher), \(try store.appliedMigrations().count) "
                    + "migrations, another key refused: \(refused)")
        }
        checks.add("file protection") {
            _ = try sentence.get()
            let entries = try ProtectedFolder.report(folder)
            let detail = entries.map { "\($0.name): \($0.protection?.rawValue ?? "none")" }.joined(separator: ", ")
            return (!entries.isEmpty && entries.allSatisfy { $0.protection == .complete }, detail)
        }
        checks.add("evidence chain") {
            _ = try sentence.get()
            let missions = try opened.get().missions
            guard let head = try missions.evidenceHead(in: Self.mission) else { return (false, "no head") }
            let result = EvidenceChain.verify(try missions.evidence(in: Self.mission), head: head,
                                              publicKeyDER: try signer.publicKeyDER())
            return (result == .valid(count: 3), "\(result)")
        }
        checks.add("trace") {
            let trace = try opened.get().missions.trace(sentence: try sentence.get(), in: Self.mission)
            let seqs = trace.evidence.map(\.seq)
            return (trace.facts.count == 1 && seqs == [1, 2], "\(trace.facts.count) fact, evidence \(seqs)")
        }
        checks.add("sealed rows") {
            _ = try sentence.get()
            let missions = try opened.get().missions
            let sealed = try missions.sealedNotes(in: Self.mission) + missions.sealedFactValues(in: Self.mission)
                + missions.sealedSentenceTexts(in: Self.mission)
                + missions.sealedEvidence(in: Self.mission).flatMap { [$0.payload, $0.file] }
            let plain = sealed.filter { $0.range(of: Data(Self.marker.utf8)) != nil }.count
            return (sealed.count == 9 && plain == 0, "\(sealed.count) sealed fields, \(plain) with plain text")
        }
    }

    private func reopenAndShred(context: LAContext?, now: Date, into checks: inout Checks) {
        let opened = Result { try UserStore.openMissions(user: Self.user, in: base, keys: keys, vault: vault,
                                                         context: context, now: now) }
        checks.add("lease ended") {
            let opened = try opened.get()
            let gone = isUnreadable { try opened.missions.notes(in: Self.oldMission) }
            let kept = try opened.missions.notes(in: Self.mission).count
            let expected = [ShredRecord(mission: Self.oldMission, reason: .leaseEnded, time: now)]
            return (opened.shredded == expected && gone && kept == 1, "shredded on open: "
                    + "\(opened.shredded.map(\.mission)), unreadable: \(gone), other kept: \(kept == 1)")
        }
        checks.add("shred order") {
            let missions = try opened.get().missions
            let records = try missions.shredAll(reason: .shredOrder, at: now, policy: FieldPolicy())
            let gone = isUnreadable { try missions.evidence(in: Self.mission) }
                && isUnreadable { try missions.notes(in: Self.mission) }
            return (records.map(\.mission) == [Self.mission] && gone,
                    "shredded: \(records.map(\.mission)), unreadable: \(gone)")
        }
        checks.add("audit log") {
            let verification = try opened.get().missions.store.verifyAudit()
            return switch verification {
            case .valid(let count): (true, "valid, \(count) events")
            case .broken(let seq, let reason): (false, "broken at \(seq): \(reason)")
            }
        }
    }

    /// A mission with 3 signed photos, a fact read from two of them and a sentence built on it, plus a
    /// mission whose lease ended. Returns the sentence's id.
    private func fill(_ missions: MissionStore, now: Date) throws -> String {
        try missions.create(mission: Self.mission, title: "Kandor rural roads \(Self.marker)", now: now)
        try missions.addNote("Culvert at km 42 \(Self.marker)", to: Self.mission)
        for (index, name) in ["photo-km42", "photo-km43", "photo-km44"].enumerated() {
            try missions.addEvidence(Capture(file: Data("\(name) \(Self.marker)".utf8), kind: .photo,
                                             capturedAt: now.addingTimeInterval(Double(index) * 60),
                                             clockSource: .device,
                                             location: EvidencePayload.Location(latE6: 12_345_678, lonE6: -23_456_789)),
                                     to: Self.mission, signer: signer)
        }
        let sources = [FactSource(seq: 1, region: nil), FactSource(seq: 2, region: nil)]
        let fact = try missions.addFact(FactInput(name: "culvert-state", value: "washed out \(Self.marker)", unit: nil,
                                                  sources: sources, rule: RuleRef(id: "store-proof", version: "1")),
                                        to: Self.mission)
        let sentence = try missions.addSentence(SentenceInput(section: "findings",
                                                              text: "The km 42 culvert is washed out. \(Self.marker)",
                                                              factIds: [fact.id]), to: Self.mission)
        try missions.create(mission: Self.oldMission, title: "Kandor old survey \(Self.marker)",
                            now: now.addingTimeInterval(-Double(KeyLease.defaultDays + 1) * KeyLease.day))
        try missions.addNote("Old note \(Self.marker)", to: Self.oldMission)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        try missions.exportEvidence(of: Self.mission, signer: signer)
            .write(to: outbox.appendingPathComponent(Self.chainFile))
        return sentence.id
    }

    /// The database files as they are on disk, for the Mac to show they cannot be read without the key.
    private func copyDatabase() throws {
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix(UserStore.fileName) {
            try FileManager.default.copyItem(at: file, to: outbox.appendingPathComponent(file.lastPathComponent))
        }
    }

    private func isUnreadable(_ read: () throws -> some Any) -> Bool {
        do { _ = try read(); return false } catch is MissionKeyNotFound { return true } catch { return false }
    }
}

/// The checks in order; a check that throws fails with the error as its detail.
private struct Checks {
    private(set) var list: [StoreProofReport.Check] = []

    mutating func add(_ name: String, _ body: () throws -> (Bool, String)) {
        do {
            let (passed, detail) = try body()
            list.append(StoreProofReport.Check(name: name, passed: passed, detail: detail))
        } catch {
            list.append(StoreProofReport.Check(name: name, passed: false, detail: "error: \(error)"))
        }
    }
}
#endif
