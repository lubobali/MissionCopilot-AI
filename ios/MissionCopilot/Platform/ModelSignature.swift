import CryptoKit
import Foundation

/// Checks a model folder against an OpenSSF Model Signing bundle before the app uses it (threat model
/// T46, docs/models/README.md). There is no official Swift verifier, so this reads the standard format:
/// a sigstore bundle whose DSSE envelope, signed with our P-256 key, holds an in-toto statement listing
/// every file's SHA-256. The folder must hold exactly those files: nothing changed, missing or added,
/// and no symlinks. Cheap checks come first; hashing the large weights comes last.
/// Stricter than the official tool in one way: it does not skip git files such as .gitattributes.
enum ModelSignature {
    enum Failure: Error, Equatable {
        case malformedBundle
        case wrongPayloadType
        case badSignature
        case wrongStatement
        case unsafeFileName(String)
        case symlink(String)
        case extraFile(String)
        case missingFile(String)
        case changedFile(String)
    }

    static let payloadType = "application/vnd.in-toto+json"

    /// The signed file names, sorted, if the folder matches the bundle; otherwise throws a `Failure`.
    static func verify(modelFolder: URL, bundle: Data, publicKey: P256.Signing.PublicKey) throws -> [String] {
        let envelope = try decode(SigstoreBundle.self, from: bundle).dsseEnvelope
        guard envelope.payloadType == payloadType else { throw Failure.wrongPayloadType }
        guard let payload = Data(base64Encoded: envelope.payload) else { throw Failure.malformedBundle }
        guard isSigned(payload, envelope: envelope, by: publicKey) else { throw Failure.badSignature }
        let resources = try checkedResources(try decode(Statement.self, from: payload))
        let listed = Set(resources.map(\.name))
        let onDisk = try regularFiles(in: modelFolder)
        if let extra = onDisk.subtracting(listed).min() { throw Failure.extraFile(extra) }
        if let missing = listed.subtracting(onDisk).min() { throw Failure.missingFile(missing) }
        for resource in resources {
            let file = modelFolder.appendingPathComponent(resource.name)
            guard try sha256Hex(of: file) == resource.digest else { throw Failure.changedFile(resource.name) }
        }
        return resources.map(\.name)
    }

    /// DSSE pre-authentication encoding: the exact bytes a DSSE signature covers.
    static func pae(payloadType: String, payload: Data) -> Data {
        let type = Data(payloadType.utf8)
        return Data("DSSEv1 \(type.count) ".utf8) + type + Data(" \(payload.count) ".utf8) + payload
    }

    private static func isSigned(_ payload: Data, envelope: Envelope, by key: P256.Signing.PublicKey) -> Bool {
        let signed = pae(payloadType: envelope.payloadType, payload: payload)
        return envelope.signatures.contains { entry in
            guard let der = Data(base64Encoded: entry.sig),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: der) else { return false }
            return key.isValidSignature(signature, for: signed)
        }
    }

    /// The statement's files, sorted by name, after checking the statement is the kind we sign.
    private static func checkedResources(_ statement: Statement) throws -> [Resource] {
        let serialization = statement.predicate.serialization
        guard statement.type == "https://in-toto.io/Statement/v1",
              statement.predicateType == "https://model_signing/signature/v1.0",
              serialization.method == "files", serialization.hashType == "sha256",
              serialization.allowSymlinks == false,
              statement.predicate.resources.allSatisfy({ $0.algorithm == "sha256" }) else {
            throw Failure.wrongStatement
        }
        let resources = statement.predicate.resources.sorted { $0.name < $1.name }
        for resource in resources where !isSafe(resource.name) {
            throw Failure.unsafeFileName(resource.name)
        }
        // The subject digest is the SHA-256 of every file digest in name order.
        var subject = SHA256()
        for resource in resources {
            guard let digest = Data(hex: resource.digest), digest.count == 32 else { throw Failure.wrongStatement }
            subject.update(data: digest)
        }
        guard statement.subject.first?.digest["sha256"] == hex(subject.finalize()) else {
            throw Failure.wrongStatement
        }
        return resources
    }

    /// A relative path that stays inside the model folder.
    private static func isSafe(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Every regular file under the folder, as paths relative to it. A symlink is refused.
    /// The listing gives relative paths itself: cutting a base path off full paths broke on the
    /// iPhone, where resolving the folder's path drops a leading /private that the listing keeps.
    private static func regularFiles(in folder: URL) throws -> Set<String> {
        let manager = FileManager.default
        guard let walk = manager.enumerator(atPath: folder.path) else { throw Failure.missingFile(".") }
        var files = Set<String>()
        for case let relative as String in walk {
            // attributesOfItem does not follow a symlink: it describes the link itself.
            let kind = try manager.attributesOfItem(atPath: folder.appendingPathComponent(relative).path)[.type]
            if kind as? FileAttributeType == .typeSymbolicLink { throw Failure.symlink(relative) }
            if kind as? FileAttributeType == .typeRegular { files.insert(relative) }
        }
        return files
    }

    /// Streams the file, so a 600 MB model never sits in memory at once.
    private static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw Failure.malformedBundle
        }
    }
}

// The bundle's JSON, as model-signing 1.1.1 writes it.
private struct SigstoreBundle: Decodable {
    let dsseEnvelope: Envelope
}

private struct Envelope: Decodable {
    let payload: String
    let payloadType: String
    let signatures: [Signature]
}

private struct Signature: Decodable {
    let sig: String
}

private struct Statement: Decodable {
    let type: String
    let subject: [Subject]
    let predicateType: String
    let predicate: Predicate

    enum CodingKeys: String, CodingKey {
        case type = "_type", subject, predicateType, predicate
    }
}

private struct Subject: Decodable {
    let digest: [String: String]
}

private struct Predicate: Decodable {
    let serialization: Serialization
    let resources: [Resource]
}

private struct Serialization: Decodable {
    let method: String
    let hashType: String
    let allowSymlinks: Bool

    enum CodingKeys: String, CodingKey {
        case method, hashType = "hash_type", allowSymlinks = "allow_symlinks"
    }
}

private struct Resource: Decodable {
    let algorithm: String
    let name: String
    let digest: String
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
