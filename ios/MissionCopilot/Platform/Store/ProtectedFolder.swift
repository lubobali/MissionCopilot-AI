import Foundation

/// One folder per user for the encrypted database (ADR 0008 layer A). Files created inside inherit
/// file protection Complete (unreadable while the phone is locked), and the folder is never backed up.
enum ProtectedFolder {
    struct UnsafeUserName: Error, Equatable { let user: String }

    struct Entry: Sendable, Equatable {
        let name: String
        let protection: FileProtectionType?
    }

    static func create(for user: String, in base: URL) throws -> URL {
        guard isSafe(user) else { throw UnsafeUserName(user: user) }
        var folder = base.appendingPathComponent(user, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }

    static func protection(of url: URL) throws -> FileProtectionType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
    }

    /// Every file in the folder with its protection, sorted by name: the on-device proof (#74).
    static func report(_ folder: URL) throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .map { Entry(name: $0.lastPathComponent, protection: try protection(of: $0)) }
            .sorted { $0.name < $1.name }
    }

    /// A user name becomes a folder name, so it must never climb out of the base folder.
    private static func isSafe(_ user: String) -> Bool {
        !user.isEmpty && user != "." && user != ".." && !user.contains("/") && !user.contains("\u{0}")
    }
}
