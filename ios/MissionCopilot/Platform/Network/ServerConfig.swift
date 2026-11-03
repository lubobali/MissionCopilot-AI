import CryptoKit
import Foundation

/// The organization's server, built into the app (#90). Its address and the public key(s) that sign
/// its mission packs and shred orders come from the Info.plist, filled at build time from
/// Config/Local.xcconfig (git-ignored; a public build has none and says so). Each key is its DER in hex
/// (an xcconfig reads // as a comment, and base64 can contain it). Keys are pinned by key id,
/// the start of the SHA-256 of the public key like the server's pack_format.key_id; more than one lets
/// the server rotate its key. Anything signed by a key that is not pinned is refused.
struct ServerConfig: Sendable {
    enum Problem: Error, Equatable { case noAddress, badAddress, noKeys, badKey }

    let base: URL
    let allowLocalHTTP: Bool
    private let keys: [String: P256.Signing.PublicKey]

    /// Plain http to the local server is for Debug builds only.
    static let allowsLocalHTTP: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    static func fromApp() throws(Problem) -> ServerConfig {
        try from(Bundle.main.infoDictionary ?? [:], allowLocalHTTP: allowsLocalHTTP)
    }

    static func from(_ info: [String: Any], allowLocalHTTP: Bool) throws(Problem) -> ServerConfig {
        let host = (info["MCServerHost"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw .noAddress }
        let scheme = info["MCServerScheme"] as? String ?? ""
        guard ["https", "http"].contains(scheme), !host.contains("/"),
              let base = URL(string: "\(scheme)://\(host)"), ServerClient.allowed(base, local: allowLocalHTTP)
        else { throw .badAddress }
        let encoded = (info["MCServerKeys"] as? String ?? "").split(whereSeparator: \.isWhitespace)
        guard !encoded.isEmpty else { throw .noKeys }
        var keys: [String: P256.Signing.PublicKey] = [:]
        for text in encoded {
            guard let der = Self.hex(String(text)),
                  let key = try? P256.Signing.PublicKey(derRepresentation: der) else { throw .badKey }
            keys[keyId(der)] = key
        }
        return ServerConfig(base: base, allowLocalHTTP: allowLocalHTTP, keys: keys)
    }

    /// The first 16 hex digits of the SHA-256 of the public key (DER), as the server names it.
    static func keyId(_ publicKeyDER: Data) -> String {
        String(SHA256.hash(data: publicKeyDER).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    func key(for keyId: String) -> P256.Signing.PublicKey? { keys[keyId] }

    private static func hex(_ text: String) -> Data? {
        guard text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
