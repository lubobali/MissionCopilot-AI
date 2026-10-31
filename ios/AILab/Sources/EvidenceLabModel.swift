import EncryptionLab
import Foundation
import Observation

/// Spike #17 proofs on the iPhone: a chip-signed evidence chain, tampering shown item by item, and an
/// export that the Python backend verifies with only the public key. Debug lab only.
@MainActor @Observable
final class EvidenceLabModel {
    struct Item: Identifiable {
        let id: Int
        let text: String
    }

    private(set) var items: [Item] = []
    private(set) var verdict = "Tap 1. Sign 3 items."
    private(set) var log: [String] = []

    private let signer = SecureEnclaveEvidenceSigner(user: "amina")
    private var chain = EvidenceChain(missionId: "kandor-roads")
    private var head: EvidenceRecord?
    private var results: [String: String] = [:]

    func signThree() {
        step {
            chain = EvidenceChain(missionId: "kandor-roads")
            let files = ["photo km 42 culvert", "photo km 43 drainage", "scan invoice 6"]
            let start = Date()
            for file in files {
                try chain.append(file: Data(file.utf8), capturedAt: Date(), signer: signer)
            }
            let signMs = Date().timeIntervalSince(start) * 1000 / Double(files.count)
            head = try chain.signedHead(signer: signer)
            record("chip sign avg ms (3 items)", String(format: "%.1f", signMs))
            try show(chain.records, label: "original")
        }
    }

    func tamperItemTwo() {
        step {
            var records = chain.records
            guard records.count == 3 else { return log("Run 1. Sign 3 items first.") }
            var payload = records[1].payload
            payload[payload.count - 3] ^= 0x01
            records[1] = EvidenceRecord(payload: payload, signature: records[1].signature)
            try show(records, label: "tamper item 2")
        }
    }

    func cutLastItem() {
        step {
            guard chain.records.count == 3 else { return log("Run 1. Sign 3 items first.") }
            try show(Array(chain.records.dropLast()), label: "cut last item")
        }
    }

    func restore() {
        step { try show(chain.records, label: "restored") }
    }

    /// Writes the chain, its head and the public key for the Python check (docs/spikes/results).
    func export() {
        step {
            guard let head, !chain.records.isEmpty else { return log("Run 1. Sign 3 items first.") }
            let export = ChainExport(publicKeyDER: try signer.publicKeyDER(), records: chain.records, head: head)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(export).write(to: DeviceInfo.documents.appendingPathComponent("evidence-chain.json"))
            log("Exported evidence-chain.json")
        }
    }

    private struct ChainExport: Codable {
        let publicKeyDER: Data
        let records: [EvidenceRecord]
        let head: EvidenceRecord
    }

    private func show(_ records: [EvidenceRecord], label: String) throws {
        guard let head else { return }
        let start = Date()
        let result = EvidenceChain.verify(records, head: head, publicKeyDER: try signer.publicKeyDER())
        let verifyMs = Date().timeIntervalSince(start) * 1000
        items = records.indices.map { index in
            switch result {
            case .broken(let at, let reason) where index == at: Item(id: index + 1, text: "❌ broken: \(reason)")
            case .broken(let at, _) where index > at: Item(id: index + 1, text: "not trusted (after the break)")
            default: Item(id: index + 1, text: "✅ signed by this phone's chip, linked")
            }
        }
        verdict = describe(result)
        record("verify \(label)", "\(verdict) (\(String(format: "%.1f", verifyMs)) ms)")
    }

    private func describe(_ result: EvidenceChain.Verification) -> String {
        switch result {
        case .valid(let count): "✅ Valid: \(count) items, head matches"
        case .broken(let at, let reason): "❌ Item \(at + 1) broke: \(reason)"
        case .brokenHead(let problem): "❌ Chain head: \(problem)"
        }
    }

    private func step(_ body: () throws -> Void) {
        do { try body() } catch { log("FAILED: \(error)") }
        save()
    }

    private func record(_ name: String, _ value: String) {
        results[name] = value
        log(name + ": " + value)
    }

    private func log(_ line: String) { log.append(line) }

    private func save() {
        guard !results.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = DeviceInfo.documents.appendingPathComponent("evidence-results.json")
        do { try encoder.encode(results).write(to: url) } catch { log("save FAILED: \(error)") }
    }
}
