import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import MissionCopilot

/// A site photo before it is signed (#129, step 6.2.8): scaled to 2048 px on its long side and re-encoded
/// as JPEG, so it is about 0.5 MB and carries no metadata at all (no place, maker or lens inside the file:
/// the place goes into the signed record instead).
struct SitePhotoTests {
    /// A photo as a camera writes it: these pixels, with GPS and maker fields in the file.
    static func cameraJPEG(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1,
                                                                        nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.86, kCGImagePropertyGPSLongitude: 87.71],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"]
        ]
        CGImageDestinationAddImage(destination, try #require(image.cgImage), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func properties(_ jpeg: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    @Test func theTestPhotoReallyCarriesAPlaceAndAMakerBeforehand() throws {
        // Proof that the next test checks something: the camera-like file has both.
        let properties = try Self.properties(try Self.cameraJPEG(width: 400, height: 300))

        #expect(properties[kCGImagePropertyGPSDictionary] != nil)
        #expect(properties[kCGImagePropertyTIFFDictionary] != nil)
    }

    @Test func aPreparedPhotoCarriesNoMetadataAtAll() throws {
        let prepared = try SitePhoto.prepare(try #require(UIImage(data: try Self.cameraJPEG(width: 400, height: 300))))
        let properties = try Self.properties(prepared)

        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal]
                == nil)
    }

    @Test func aLargePhotoIsScaledTo2048OnItsLongSideAndKeepsItsShape() throws {
        let camera = try #require(UIImage(data: try Self.cameraJPEG(width: 4032, height: 3024)))

        let prepared = try #require(UIImage(data: try SitePhoto.prepare(camera)))

        #expect(prepared.size.width * prepared.scale == 2048)
        #expect(prepared.size.height * prepared.scale == 1536)
    }

    @Test func aSmallPhotoIsNeverMadeLarger() throws {
        let small = try #require(UIImage(data: try Self.cameraJPEG(width: 800, height: 600)))

        let prepared = try #require(UIImage(data: try SitePhoto.prepare(small)))

        #expect(prepared.size.width * prepared.scale == 800)
    }

    @Test func thePreparedPhotoIsAJPEG() throws {
        let prepared = try SitePhoto.prepare(try #require(UIImage(data: try Self.cameraJPEG(width: 400, height: 300))))

        #expect(prepared.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test(arguments: [(CameraAccess.denied, "en"), (.restricted, "en"), (.noCamera, "en"), (.denied, "fr")])
    func everyWayTheCameraCannotOpenSaysWhatToDo(access: CameraAccess, language: String) {
        let problem = access.problem(app: "MC Staging", language: language)

        #expect(problem?.isEmpty == false)
        #expect(CameraAccess.ready.problem(app: "MC Staging", language: language) == nil)
        #expect(CameraAccess.notAsked.problem(app: "MC Staging", language: language) == nil)
    }

    @Test func theCameraWordsAreTheOnesWeMean() {
        #expect(CameraAccess.denied.problem(app: "MC Staging", language: "en")
                == "The camera is off for MC Staging. Turn it on in Settings, then try again.")
        #expect(CameraAccess.noCamera.problem(app: "MC Staging", language: "en")
                == "This iPhone has no camera the app can use.")
        #expect(CameraAccess.denied.problem(app: "MC Staging", language: "fr")
                == "L'appareil photo est désactivé pour MC Staging. Activez-le dans Réglages, puis réessayez.")
    }
}
