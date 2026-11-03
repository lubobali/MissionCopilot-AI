import CoreGraphics
@testable import MissionCopilot

/// Reads the color of one pixel of a rendered view, by drawing it into a known sRGB buffer.
enum Pixel {
    static func rgb(_ image: CGImage, column: Int, row: Int) -> RGB? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: -column, y: row - image.height + 1, width: image.width, height: image.height))
        return RGB(hex: UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2]))
    }
}
