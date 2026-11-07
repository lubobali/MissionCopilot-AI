import CryptoKit
import Foundation

/// A pack file as the signed manifest names it: its path and the SHA-256 of its bytes (#134).
struct PackFileRef: Codable, Sendable, Equatable {
    let path: String
    let sha256: String

    init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }

    init(path: String, data: Data) {
        self.init(path: path, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func cite(_ pointer: String) -> PackCitation { PackCitation(path: path, sha256: sha256, pointer: pointer) }
}

/// Where one input of a red flag came from: a pack file and a JSON Pointer (RFC 6901) to the field. It can
/// be read again, but only from the very file it names (the hash must match).
struct PackCitation: Codable, Sendable, Equatable {
    struct CannotRead: Error, Equatable { let why: String }

    let path: String
    let sha256: String
    let pointer: String

    func value(in data: Data) throws(CannotRead) -> JSONValue {
        guard PackFileRef(path: path, data: data).sha256 == sha256 else { throw CannotRead(why: "another file") }
        guard pointer.hasPrefix("/"), let root = try? JSONValue.parse(data) else { throw CannotRead(why: "pointer") }
        var value = root
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch value {
            case .object(let fields): guard let next = fields[token] else { throw CannotRead(why: "no \(token)") }
                value = next
            case .array(let items): guard let index = Int(token), items.indices.contains(index)
                else { throw CannotRead(why: "no item \(token)") }
                value = items[index]
            default: throw CannotRead(why: "nothing inside \(token)")
            }
        }
        return value
    }
}

/// The pack's contracts (Open Contracting style): the value, the payments and the physical progress the
/// red-flag rules compare (#134). Read only after the import's schema check.
struct PackContracts: Sendable, Equatable {
    struct Payment: Codable, Sendable, Equatable {
        let amount: Int
        let date: String
        let reference: String
    }

    struct Progress: Codable, Sendable, Equatable {
        let asOf: String
        let kmBuilt: Double
        let kmTotal: Double
        let unit: String
    }

    enum Status: String, Codable, Sendable { case pending, active, complete, cancelled }

    struct Contract: Codable, Sendable, Equatable {
        let ocid: String
        let title: String
        let supplier: String
        let status: Status
        let contractValue: Int
        let payments: [Payment]
        let physicalProgress: Progress
    }

    private struct File: Codable { let contracts: [Contract] }

    static let path = "sections/contracts.json"
    let file: PackFileRef
    let contracts: [Contract]

    static func read(_ data: Data) throws -> PackContracts {
        PackContracts(file: PackFileRef(path: path, data: data),
                      contracts: try JSONDecoder().decode(File.self, from: data).contracts)
    }
}

/// The pack's milestones with their due and met days (#134).
struct PackMilestones: Sendable, Equatable {
    enum Status: String, Codable, Sendable { case scheduled, met, notMet, partiallyMet }

    struct Milestone: Codable, Sendable, Equatable {
        let id: String
        let title: String
        let dueDate: String
        let dateMet: String?
        let status: Status
    }

    private struct File: Codable {
        let asOf: String
        let milestones: [Milestone]
    }

    static let path = "sections/milestones.json"
    let file: PackFileRef
    let asOf: String
    let milestones: [Milestone]

    static func read(_ data: Data) throws -> PackMilestones {
        let decoded = try JSONDecoder().decode(File.self, from: data)
        return PackMilestones(file: PackFileRef(path: path, data: data), asOf: decoded.asOf,
                              milestones: decoded.milestones)
    }
}
