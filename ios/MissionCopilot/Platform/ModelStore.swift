import Foundation

/// Where on-device AI model files live.
/// Model weights are public (not mission data), so they use "complete until first user
/// authentication": the model can still load while the phone is locked. They are excluded from
/// backups because they are large and can be re-downloaded. Mission data uses stricter rules (ADR 0008).
struct ModelStore {
    let applicationSupport: URL
    /// Files dropped in through Finder file sharing (Debug builds) arrive here.
    let inbox: URL

    private var modelsFolder: URL {
        applicationSupport.appendingPathComponent("models", isDirectory: true)
    }

    /// The real locations on the device.
    static func live() throws -> ModelStore {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let documents = try fileManager.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return ModelStore(applicationSupport: support, inbox: documents)
    }

    @discardableResult
    func prepareModelsFolder() throws -> URL {
        var folder = modelsFolder
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }

    /// Moves model files (`.gguf`) and MLX model folders (containing `config.json`) from the inbox.
    func importFromInbox() throws -> [String] {
        let folder = try prepareModelsFolder()
        var imported: [String] = []
        for item in try contents(of: inbox) where isModel(item) {
            let destination = folder.appendingPathComponent(item.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: item, to: destination)
            imported.append(item.lastPathComponent)
        }
        return imported.sorted()
    }

    func installedModels() throws -> [String] {
        try contents(of: modelsFolder).filter(isModel).map(\.lastPathComponent).sorted()
    }

    private func contents(of folder: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    }

    private func isModel(_ url: URL) -> Bool {
        if url.pathExtension == "gguf" { return true }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path)
    }
}
