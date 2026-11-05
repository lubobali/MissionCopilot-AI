import CryptoKit
import Foundation

/// The on-device model that ships inside the app (#125; Lubo, Nov 5: ready on install, never a separate
/// download). scripts/bundle_model.py copies exactly the signed files and their OpenSSF Model Signing
/// bundle into Models/ for Staging and Release; Debug builds and a Mac without the model ship none. The
/// app bundle is read-only and inside the signed app, but the model is still checked against our pinned
/// key before it is trusted (threat model T46): a changed, missing or extra file refuses it.
enum BundledModel {
    static let name = "LFM2.5-1.2B-Instruct-4bit"
    static let folder = "Models"

    enum State: Equatable, Sendable {
        case verified(files: Int)
        /// Debug builds and builds made without the model (CI).
        case notInThisBuild
        case refused(ModelStore.Refusal)
    }

    static func modelFolder(in resources: URL) -> URL {
        resources.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// Checks the model in `resources` (the app's: `Bundle.main.resourceURL`). Hashing 633 MB takes about
    /// half a second on an iPhone 13 Pro Max, so it runs off the main actor.
    @concurrent
    static func check(resources: URL?, publicKey: P256.Signing.PublicKey = ModelStore.pinnedKey) async -> State {
        guard let resources else { return .notInThisBuild }
        let model = modelFolder(in: resources)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: model.path, isDirectory: &isFolder), isFolder.boolValue else {
            return .notInThisBuild
        }
        let signature = model.deletingLastPathComponent().appendingPathComponent("\(name).sig")
        guard let bundle = try? Data(contentsOf: signature) else { return .refused(.unsigned) }
        do {
            return .verified(files: try ModelSignature.verify(modelFolder: model, bundle: bundle,
                                                              publicKey: publicKey).count)
        } catch let failure as ModelSignature.Failure {
            return .refused(.signature(failure))
        } catch {
            return .refused(.signature(.malformedBundle))
        }
    }
}
