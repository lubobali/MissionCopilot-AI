import Foundation

/// Where a mission pack waits while it downloads (#91). One folder per mission, never backed up. Its files
/// are protected "until first user authentication": a download may go on in the background after the phone
/// locks, and a Complete file cannot be written then. They hold signed pack content for minutes only and
/// are removed once the pack is in the encrypted store (threat model T51). Every file is named by its
/// SHA-256, so a name from a manifest can never reach outside the folder: "<sha>.part" while it arrives,
/// "<sha>" once it is exactly what its manifest entry says. Paths for FileManager are written out unencoded:
/// the app's folder is "Application Support", and "Application%20Support" names a folder that does not
/// exist (found on the iPhone, #94).
struct PackStaging: Sendable {
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    let folder: URL

    init(base: URL, mission: String) throws {
        guard (try? /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/.wholeMatch(in: mission)) != nil
        else { throw PackRefusal.wrongMission }
        var folder = base.appendingPathComponent(mission, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: Self.protection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        self.folder = folder
    }

    /// A path for FileManager, unencoded (see above).
    static func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    private func partURL(_ file: PackFileEntry) -> URL { folder.appending(path: "\(file.sha256).part") }
    private func readyURL(_ file: PackFileEntry) -> URL { folder.appending(path: file.sha256) }

    func partialSize(of file: PackFileEntry) throws -> Int {
        guard FileManager.default.fileExists(atPath: Self.path(partURL(file))) else { return 0 }
        let size = try FileManager.default.attributesOfItem(atPath: Self.path(partURL(file)))[.size] as? Int
        return size ?? 0
    }

    func partial(of file: PackFileEntry) throws -> Data { try Data(contentsOf: partURL(file)) }

    func append(_ data: Data, to file: PackFileEntry) throws {
        let url = partURL(file)
        if !FileManager.default.fileExists(atPath: Self.path(url)) {
            guard FileManager.default.createFile(atPath: Self.path(url), contents: nil,
                                                 attributes: [.protectionKey: Self.protection])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// The half-done file becomes the ready file only if it matches its entry; otherwise it is deleted.
    func finish(_ file: PackFileEntry) throws {
        let data = try partial(of: file)
        do {
            try PackVerifier.check(file, data: data)
        } catch {
            try restart(file)
            throw error
        }
        try? FileManager.default.removeItem(at: readyURL(file))
        try FileManager.default.moveItem(at: partURL(file), to: readyURL(file))
    }

    /// Ready only while the file on disk is still exactly what its entry says.
    func isReady(_ file: PackFileEntry) -> Bool {
        guard let data = try? Data(contentsOf: readyURL(file)) else { return false }
        return (try? PackVerifier.check(file, data: data)) != nil
    }

    func ready(_ file: PackFileEntry) throws -> Data { try Data(contentsOf: readyURL(file)) }

    /// A file taken from the phone's own store (#94) becomes a ready file, only if it matches its entry.
    func place(_ data: Data, as file: PackFileEntry) throws {
        try PackVerifier.check(file, data: data)
        guard FileManager.default.createFile(atPath: Self.path(readyURL(file)), contents: data,
                                             attributes: [.protectionKey: Self.protection])
        else { throw CocoaError(.fileWriteUnknown) }
    }

    func restart(_ file: PackFileEntry) throws {
        if FileManager.default.fileExists(atPath: Self.path(partURL(file))) {
            try FileManager.default.removeItem(at: partURL(file))
        }
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: Self.path(folder)) { try FileManager.default.removeItem(at: folder) }
    }
}
