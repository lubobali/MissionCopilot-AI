import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A site photo made ready to sign (#129): scaled to 2048 px on its long side (about 0.5 MB, still sharp
/// enough for evidence) and written as a new JPEG with no metadata at all. The camera's file can hold the
/// place, the maker, the lens and the time; none of it is kept in the file. The place and the time go into
/// the signed evidence record instead, where they cannot be changed without breaking the signature.
enum SitePhoto {
    static let longSide: CGFloat = 2048
    static let quality = 0.8

    struct CannotEncode: Error {}

    static func prepare(_ image: UIImage) throws -> Data {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let shrink = min(1, longSide / max(pixels.width, pixels.height))
        let size = CGSize(width: (pixels.width * shrink).rounded(), height: (pixels.height * shrink).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Drawing bakes the camera's orientation into the pixels, so no orientation field is needed either.
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let pixelsOnly = drawn.cgImage else { throw CannotEncode() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CannotEncode() }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, pixelsOnly, options)
        guard CGImageDestinationFinalize(destination) else { throw CannotEncode() }
        return data as Data
    }
}

/// Whether the camera can open, in words the officer can act on (#129). Asked for only when the officer
/// taps Take photo (MASVS-PRIVACY-1).
enum CameraAccess: Equatable, Sendable {
    case ready, notAsked, denied, restricted, noCamera

    @MainActor
    static func current() -> CameraAccess {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return .noCamera }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .ready
        case .notDetermined: return .notAsked  // iOS asks when the camera opens
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    /// What stops the camera and what to do, or nil when it can open.
    func problem(app: String, language: String) -> String? {
        let french = language == "fr"
        switch self {
        case .ready, .notAsked: return nil
        case .denied:
            return french ? "L'appareil photo est désactivé pour \(app). Activez-le dans Réglages, puis réessayez."
                : "The camera is off for \(app). Turn it on in Settings, then try again."
        case .restricted:
            return french ? "L'appareil photo est bloqué sur cet iPhone par ses réglages ou par votre organisation."
                : "The camera is blocked on this iPhone by its settings or your organization."
        case .noCamera:
            return french ? "Cet iPhone n'a pas d'appareil photo utilisable par l'application."
                : "This iPhone has no camera the app can use."
        }
    }
}
