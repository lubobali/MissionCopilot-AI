import Foundation

/// The API contract's rules for a manifest (docs/api/openapi.yaml, MissionPack), checked on the parsed
/// JSON exactly as the server's check_manifest does: no unknown or missing field, the right types (a
/// boolean or a decimal is not a whole number), the patterns, 1 to 64 files in fixed folders with plain
/// names, at most 20 MiB a file and 50 MiB together.
extension PackVerifier {
    static let maxFiles = 64
    static let maxFileBytes = 20 * 1024 * 1024
    static let maxPackBytes = 50 * 1024 * 1024
    static let mediaTypes: Set<String> = ["application/json", "text/markdown", "application/pdf", "image/jpeg"]

    private static let manifestKeys: Set<String> = [
        "format", "formatVersion", "packId", "orgId", "missionId", "version", "createdAt", "expiresAt",
        "minAppVersion", "keyId", "files"
    ]
    private static let fileKeys: Set<String> = ["path", "sha256", "size", "mediaType"]
    // Computed: Regex is not Sendable, so it cannot be a stored static under Swift 6.
    private static var uuid: Regex<Substring> { /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/ }
    private static var org: Regex<Substring> { /[a-z0-9][a-z0-9-]{1,39}/ }
    private static var appVersionPattern: Regex<Substring> { /[0-9]+\.[0-9]+(?:\.[0-9]+)?/ }
    private static var keyIdPattern: Regex<Substring> { /[0-9a-f]{16}/ }
    private static var sha: Regex<Substring> { /[0-9a-f]{64}/ }
    private static var path: Regex<Substring> {
        /(?:sections|forms|documents)\/[a-z0-9][a-z0-9-]{0,62}\.(?:json|md|pdf|jpg)/
    }
    private static var time: Regex<Substring> { /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/ }

    static func rules(_ object: Any) throws(PackRefusal) -> PackManifest {
        guard let fields = object as? [String: Any], Set(fields.keys) == manifestKeys,
              fields["format"] as? String == "missioncopilot-pack", integer(fields["formatVersion"]) == 2,
              let packId = text(fields["packId"], uuid), let orgId = text(fields["orgId"], org),
              let missionId = text(fields["missionId"], uuid), let version = integer(fields["version"]), version >= 1,
              let created = date(fields["createdAt"]), let expires = date(fields["expiresAt"]),
              let minApp = text(fields["minAppVersion"], appVersionPattern),
              let keyId = text(fields["keyId"], keyIdPattern),
              let list = fields["files"] as? [Any], (1...maxFiles).contains(list.count) else { throw .malformed }
        var files: [PackFileEntry] = []
        for item in list {
            guard let entry = file(item) else { throw .malformed }
            files.append(entry)
        }
        guard files.reduce(0, { $0 + $1.size }) <= maxPackBytes else { throw .malformed }
        return PackManifest(packId: packId, orgId: orgId, missionId: missionId, version: version, createdAt: created,
                            expiresAt: expires, minAppVersion: minApp, keyId: keyId, files: files)
    }

    private static func file(_ item: Any) -> PackFileEntry? {
        guard let fields = item as? [String: Any], Set(fields.keys) == fileKeys,
              let path = text(fields["path"], path), let sha = text(fields["sha256"], sha),
              let size = integer(fields["size"]), (0...maxFileBytes).contains(size),
              let media = fields["mediaType"] as? String, mediaTypes.contains(media) else { return nil }
        return PackFileEntry(path: path, sha256: sha, size: size, mediaType: media)
    }

    /// A whole number: JSON true and 2.0 come back as NSNumber too, so both are refused here.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.intValue
    }

    private static func text(_ value: Any?, _ pattern: Regex<Substring>) -> String? {
        guard let string = value as? String, (try? pattern.wholeMatch(in: string)) != nil else { return nil }
        return string
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = text(value, time) else { return nil }
        return try? Date(string, strategy: .iso8601)
    }
}
