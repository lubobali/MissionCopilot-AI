import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// Report sources (#162, decided A): every source a report sentence can cite becomes evidence with facts, so
/// ADR 0009's one path (sentence -> facts -> evidence) covers the whole report. The pack keeps the server's
/// signature; the pack and the finished walk become evidence items; code writes facts from the pack's records,
/// the walk's answers and the red flags.
struct ReportSourcesTests {
    static let mission = PackDownloaderTests.mission

    // MARK: 7.1.1 the pack keeps the server's signature

    /// The downloader passes on the signature it checked, and the import keeps it with the manifest.
    @Test func theServersSignatureIsKeptWithThePack() async throws {
        let rig = try PackDownloaderTests.Rig()
        guard case .verified(let ready) = await rig.run() else { throw CancellationError() }

        #expect(ready.signature == FakePackServer.file("signature.json"))
        let store = try Self.emptyStore()
        _ = try PackImport.run(ready, title: "Kandor", into: store, schema: PackSectionsTests.schema())

        #expect(try store.packSignature(in: Self.mission) == FakePackServer.file("signature.json"))
    }

    /// A pack imported before #162 has no signature kept: nil, never an error.
    @Test func aPackWithoutAKeptSignatureGivesNil() async throws {
        let rig = try PackDownloaderTests.Rig()
        guard case .verified(var ready) = await rig.run() else { throw CancellationError() }
        ready.signature = nil
        let store = try Self.emptyStore()
        _ = try PackImport.run(ready, title: "Kandor", into: store, schema: PackSectionsTests.schema())

        #expect(try store.packSignature(in: Self.mission) == nil)
        #expect(try store.packSignature(in: "no-such-mission") == nil)
    }

    // MARK: 7.1.3 and 7.1.4 the pack and the finished walk as evidence

    /// The pack is evidence once per manifest: its exact manifest bytes and the server's signature, signed into
    /// the phone's chain (kind pack); asking again gives the same item.
    @Test func thePackBecomesEvidenceOnce() async throws {
        let (store, _) = try await AskOpeningTests.store()
        let before = try store.evidence(in: Self.mission).count

        let seq = try store.packEvidence(in: Self.mission, signer: SoftwareEvidenceSigner())
        let again = try store.packEvidence(in: Self.mission, signer: SoftwareEvidenceSigner())

        #expect(seq == before + 1 && again == seq)
        #expect(try store.evidence(in: Self.mission).count == before + 1)
        let payload = try Self.payload(store, seq)
        #expect(payload.kind == .pack)
        let file = try JSONDecoder().decode(PackEvidenceFile.self, from: store.evidenceFile(in: Self.mission, seq: seq))
        #expect(file.manifestSHA256 == (try store.storedPack(for: Self.mission))?.manifestSHA256)
        #expect(PackAcceptance.hash(file.manifest) == file.manifestSHA256)
        #expect(file.signature == FakePackServer.file("signature.json"))
        #expect(payload.contentHash == SHA256.hash(data: try store.evidenceFile(in: Self.mission, seq: seq))
            .map { String(format: "%02x", $0) }.joined())
    }

    /// A newer pack is a new manifest, so it becomes evidence of its own; the first item stays.
    @Test func aNewerPackIsEvidenceOfItsOwn() async throws {
        let rig = try PackDownloaderTests.Rig()
        guard case .verified(let first) = await rig.run() else { throw CancellationError() }
        let store = try Self.emptyStore()
        _ = try PackImport.run(first, title: "Kandor", into: store, schema: PackSectionsTests.schema())
        let one = try store.packEvidence(in: Self.mission, signer: SoftwareEvidenceSigner())

        _ = try PackImport.run(try PackImportTests.republished(first, version: first.manifest.version + 1),
                               title: "Kandor", into: store, schema: PackSectionsTests.schema())
        let two = try store.packEvidence(in: Self.mission, signer: SoftwareEvidenceSigner())

        #expect(two == one + 1)
        #expect(try Self.payload(store, one).kind == .pack)
    }

    /// The walk is evidence only once it is finished, and once: its answers and checks as canonical JSON.
    @Test func theFinishedWalkBecomesEvidenceOnce() async throws {
        let (store, _) = try await AskOpeningTests.store()
        let form = SiteWalkStoreTests.form

        #expect(throws: MissionStore.WalkNotFinished.self) {
            try store.walkEvidence(form: form, in: Self.mission, signer: SoftwareEvidenceSigner())
        }
        try store.finishWalk(form: form, version: "1", mission: Self.mission)
        let seq = try store.walkEvidence(form: form, in: Self.mission, signer: SoftwareEvidenceSigner())
        let again = try store.walkEvidence(form: form, in: Self.mission, signer: SoftwareEvidenceSigner())

        #expect(again == seq)
        #expect(try Self.payload(store, seq).kind == .walk)
        let file = try JSONDecoder().decode(WalkEvidenceFile.self, from: store.evidenceFile(in: Self.mission, seq: seq))
        #expect(file.formId == form && file.formVersion == "1")
        #expect(file.answers["bridge_started"] == "no")
    }

    /// The same walk always gives the same bytes (sorted keys, whole seconds), so its hash can be checked.
    @Test func theWalksEvidenceBytesAreCanonical() throws {
        let walk = WalkEvidenceFile(formId: "f", formVersion: "1", finishedAt: 1_700_000_000,
                                    answers: ["b": "2", "a": "1"],
                                    checks: ["x": .init(seen: "done", note: nil, photo: 3)])

        let bytes = try WalkEvidenceFile.encoder.encode(walk)

        #expect(String(bytes: bytes, encoding: .utf8) == #"{"answers":{"a":"1","b":"2"},"checks":{"x":{"photo":3,"#
            + #""seen":"done"}},"finishedAt":1700000000,"formId":"f","formVersion":"1"}"#)
    }

    // MARK: 7.1.5 facts from the pack, the walk and the red flags

    /// The finished Kandor walk, with the red flags of its pack.
    static func finished() async throws -> (MissionStore, [RedFlagResult]) {
        let (store, _) = try await AskOpeningTests.store()
        try store.finishWalk(form: SiteWalkStoreTests.form, version: "1", mission: mission)
        let flags = RedFlagEngine(rules: RedFlagEngineTests.rules).run(RedFlagInputs(
            contracts: try PackContracts.read(store.packFile(PackContracts.path, in: mission)),
            milestones: try PackMilestones.read(store.packFile(PackMilestones.path, in: mission))),
            walk: RedFlagEngineTests.walkDay, timeZone: .gmt)
        return (store, flags)
    }

    static func write(_ store: MissionStore, _ flags: [RedFlagResult]) throws -> [Fact] {
        try store.reportFacts(in: mission, form: SiteWalkStoreTests.form, flags: flags,
                              signer: SoftwareEvidenceSigner())
    }

    /// Bank records the report uses become pack-record facts citing the pack's evidence, the file and pointer.
    @Test func bankRecordsBecomeFactsCitingThePack() async throws {
        let (store, flags) = try await Self.finished()

        let facts = try Self.write(store, flags)

        let pack = try store.packEvidence(in: Self.mission, signer: SoftwareEvidenceSigner())
        let records = facts.filter { $0.rule == ReportRules.packRecord }
        let milestone = try #require(records.first { $0.name == "pack:sections/milestones.json#/milestones/2" })
        #expect(milestone.value.contains("status: notMet"), "\(milestone.value)")
        #expect(milestone.sources.count == 1 && milestone.sources[0].seq == pack)
        let file = try #require(try store.storedPack(for: Self.mission)?.files.first {
            $0.path == "sections/milestones.json"
        })
        #expect(milestone.sources[0].region == "sections/milestones.json#/milestones/2 sha256:\(file.sha256)")
        for name in ["pack:sections/contracts.json#/contracts/0", "pack:sections/agreed-actions.json#/actions/0",
                     "pack:sections/contracts.json#/contracts/0/payments/5",
                     "pack:sections/contracts.json#/contracts/0/payments#paid",
                     "pack:sections/ratings.json#/overallRisk"] {
            #expect(records.contains { $0.name == name }, "\(name)")
        }
        #expect(!records.contains { $0.name.contains("indicators") }, "only what a report uses")
    }

    /// Each walk answer and action check becomes a walk-answer fact citing the walk's evidence and the question.
    @Test func walkAnswersBecomeFactsCitingTheWalk() async throws {
        let (store, flags) = try await Self.finished()

        let facts = try Self.write(store, flags)

        let walk = try store.walkEvidence(form: SiteWalkStoreTests.form, in: Self.mission,
                                          signer: SoftwareEvidenceSigner())
        let answer = try #require(facts.first { $0.rule == ReportRules.walkAnswer && $0.name == "walk:bridge_started" })
        #expect(answer.value == "no")
        #expect(answer.sources == [FactSource(seq: walk, region: "question:bridge_started")])
    }

    /// Each red flag with inputs becomes a red-flag fact citing its inputs' evidence, strictly confidential.
    @Test func redFlagsBecomeFactsCitingTheirInputs() async throws {
        let (store, flags) = try await Self.finished()

        let facts = try Self.write(store, flags)

        let pack = try store.packEvidence(in: Self.mission, signer: SoftwareEvidenceSigner())
        let ahead = try #require(facts.first { $0.rule == ReportRules.redFlag && $0.name.hasPrefix("flag:MC-01") })
        #expect(ahead.value.hasPrefix("flag"), "\(ahead.value)")
        // One link to the pack's evidence (a fact cites each item once), naming every field the flag used.
        #expect(ahead.sources.count == 1 && ahead.sources[0].seq == pack)
        let fields = ahead.sources[0].region?.components(separatedBy: " | ") ?? []
        #expect(fields.count > 1 && fields.allSatisfy { $0.contains("sha256:") }, "\(fields)")
        #expect(ahead.classification == .strictlyConfidential)
        #expect(facts.filter { $0.rule == ReportRules.redFlag }.count
                == flags.filter { !$0.inputs.isEmpty }.count)
    }

    /// Writing again adds nothing; the facts are the same.
    @Test func reportFactsAreWrittenOnce() async throws {
        let (store, flags) = try await Self.finished()

        let first = try Self.write(store, flags)
        let again = try Self.write(store, flags)

        #expect(first.map(\.id) == again.map(\.id))
        #expect(try store.facts(in: Self.mission).count == first.count)
    }

    /// Before the walk is finished there is no walk evidence: pack and flag facts only.
    @Test func beforeTheFinishThereAreNoWalkFacts() async throws {
        let (store, _) = try await AskOpeningTests.store()

        let facts = try Self.write(store, [])

        #expect(!facts.isEmpty && facts.allSatisfy { $0.rule == ReportRules.packRecord })
    }

    /// Ask reads the pack, walk and flags directly: these facts never show there twice.
    @Test func reportFactsStayOutOfAsk() async throws {
        let (store, flags) = try await Self.finished()
        _ = try Self.write(store, flags)

        let inputs = MissionSources.records(mission: Self.mission, store: store)

        #expect(!inputs.facts.contains { ReportRules.ids.contains($0.rule.id) })
        #expect(ScannedInvoice.all(from: try store.facts(in: Self.mission)).isEmpty)
    }

    // MARK: 7.1.6 trace

    /// A report sentence on these facts traces back to the pack's evidence (the manifest the server signed)
    /// and the walk's evidence, each fact naming the file and pointer or the question it came from.
    @Test func aReportSentenceTracesToThePackAndTheWalk() async throws {
        let (store, flags) = try await Self.finished()
        let facts = try Self.write(store, flags)
        let milestone = try #require(facts.first { $0.name == "pack:sections/milestones.json#/milestones/2" })
        let walked = try #require(facts.first { $0.name == "walk:bridge_started" })

        let sentence = try store.addSentence(SentenceInput(section: "findings",
                                                           text: "The Section 3 bridge is late and not started.",
                                                           factIds: [milestone.id, walked.id]), to: Self.mission)
        let trace = try store.trace(sentence: sentence.id, in: Self.mission)

        #expect(trace.facts.map(\.id) == [milestone.id, walked.id])
        let kinds = try trace.evidence.map {
            try JSONDecoder().decode(EvidencePayload.self, from: $0.record.payload).kind
        }
        #expect(kinds == [.pack, .walk])
        let file = try JSONDecoder().decode(PackEvidenceFile.self,
                                            from: store.evidenceFile(in: Self.mission, seq: trace.evidence[0].seq))
        #expect(file.manifestSHA256 == (try store.storedPack(for: Self.mission))?.manifestSHA256)
        #expect(trace.facts[0].sources[0].region?.hasPrefix("sections/milestones.json#/milestones/2 sha256:") == true)
        #expect(trace.facts[1].sources[0].region == "question:bridge_started")
        #expect(sentence.classification == .officialUseOnly)
    }

    static func payload(_ store: MissionStore, _ seq: Int) throws -> EvidencePayload {
        try JSONDecoder().decode(EvidencePayload.self, from: store.evidence(in: mission)[seq - 1].payload)
    }

    static func emptyStore() throws -> MissionStore {
        try MissionStore(store: EncryptedStore.open(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite"),
            key: DataKey.random()), vault: SoftwareKeyVault())
    }
}
