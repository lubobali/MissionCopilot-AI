import Foundation

/// WCAG 2.2 contrast between two colors, from 1:1 (same) to 21:1 (black on white).
enum Contrast {
    static func ratio(_ first: RGB, _ second: RGB) -> Double {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// AA (4.5:1) normally; AAA (7:1) when the phone asks for increased contrast.
    static func required(_ mode: ColorMode) -> Double {
        mode.isHighContrast ? 7 : 4.5
    }

    private static func luminance(_ color: RGB) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

extension Palette {
    /// Every place a role is used as text, and what it sits on. The contrast test checks each one, so a
    /// role that is not listed here (the cyan decoration) is never text.
    static let textPairs: [(text: ColorRole, on: ColorRole)] =
        [ColorRole.text, .secondaryText, .accent, .success, .warning, .danger]
            .flatMap { role in [(role, ColorRole.background), (role, .surface)] }
            + [(.onAccent, .accent)]
}
