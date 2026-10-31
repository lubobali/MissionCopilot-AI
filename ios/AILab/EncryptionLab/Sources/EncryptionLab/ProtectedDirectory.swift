import Foundation

/// One folder per user for their encrypted database (ADR 0008, layer 1: iOS Data Protection).
/// Files created inside inherit protection Complete: unreadable while the phone is locked.
public enum ProtectedDirectory {
    public struct UnsafeUserName: Error {
        public let user: String
    }

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let protection: FileProtectionType?
    }

    public static func create(for user: String, in base: URL) throws -> URL {
        guard isSafe(user) else { throw UnsafeUserName(user: user) }
        var folder = base.appendingPathComponent(user, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }

    public static func protection(of url: URL) throws -> FileProtectionType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
    }

    /// Every file in the folder with its protection, sorted by name: the on-device proof.
    public static func report(_ folder: URL) throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .map { Entry(name: $0.lastPathComponent, protection: try protection(of: $0)) }
            .sorted { $0.name < $1.name }
    }

    /// A user name becomes a folder name, so it must never climb out of the base folder.
    private static func isSafe(_ user: String) -> Bool {
        !user.isEmpty && user != "." && user != ".." && !user.contains("/")
    }
}
