import CryptoKit
import Foundation

/// Where on-device AI model files live.
/// Model weights are public (not mission data), so they use "complete until first user
/// authentication": the model can still load while the phone is locked. They are excluded from
/// backups because they are large and can be re-downloaded. Mission data uses stricter rules (ADR 0008).
/// A model is imported only with a valid OpenSSF Model Signing bundle next to it, and checked again
/// before it loads (threat model T46).
struct ModelStore {
    let applicationSupport: URL
    /// Files dropped in through Finder file sharing (Debug builds) arrive here.
    let inbox: URL
    var publicKey: P256.Signing.PublicKey = Self.pinnedKey

    enum Refusal: Equatable {
        /// No signature bundle next to the model, or not a signed model folder (a .gguf file).
        case unsigned
        case signature(ModelSignature.Failure)
    }

    struct ImportResult: Equatable {
        var imported: [String] = []
        var refused: [String: Refusal] = [:]
    }

    // The pinned key is a compile-time constant; a bad one must stop the app, not be skipped.
    // swiftlint:disable:next force_try
    static let pinnedKey = try! P256.Signing.PublicKey(pemRepresentation: ModelSigningKey.pem)

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

    /// Moves MLX model folders (containing `config.json`) whose `<name>.sig` bundle verifies from the
    /// inbox, with their bundle. Anything else stays in the inbox and is reported as refused.
    func importFromInbox() throws -> ImportResult {
        let folder = try prepareModelsFolder()
        var result = ImportResult()
        for item in try contents(of: inbox) {
            let name = item.lastPathComponent
            if item.pathExtension == "gguf" {
                result.refused[name] = .unsigned
                continue
            }
            guard isModel(item) else { continue }
            let signature = inbox.appendingPathComponent("\(name).sig")
            guard let bundle = try? Data(contentsOf: signature) else {
                result.refused[name] = .unsigned
                continue
            }
            do {
                _ = try ModelSignature.verify(modelFolder: item, bundle: bundle, publicKey: publicKey)
            } catch let failure as ModelSignature.Failure {
                result.refused[name] = .signature(failure)
                continue
            }
            try replace(folder.appendingPathComponent(name), with: item)
            try replace(folder.appendingPathComponent("\(name).sig"), with: signature)
            result.imported.append(name)
        }
        result.imported.sort()
        return result
    }

    func installedModels() throws -> [String] {
        try contents(of: modelsFolder).filter(isModel).map(\.lastPathComponent).sorted()
    }

    /// The installed model's folder, after checking it against its bundle again: an engine calls this
    /// right before loading, so a model changed after import is never used.
    func verifiedModel(named name: String) throws -> URL {
        let model = modelsFolder.appendingPathComponent(name, isDirectory: true)
        let bundle = try Data(contentsOf: modelsFolder.appendingPathComponent("\(name).sig"))
        _ = try ModelSignature.verify(modelFolder: model, bundle: bundle, publicKey: publicKey)
        return model
    }

    private func replace(_ destination: URL, with item: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: item, to: destination)
    }

    private func contents(of folder: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    }

    private func isModel(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path)
    }
}
