import SwiftUI
import Testing
import UIKit
@testable import MissionCopilot

/// The Field Navy palette (#87): every color is a named role with a value for light, dark and increased
/// contrast, and the colors on screen follow the phone's settings.
struct PaletteTests {
    @Test func theLightPaletteUsesTheAgreedColors() {
        #expect(Palette.rgb(.background, .light) == RGB(hex: 0xF5F7F9))
        #expect(Palette.rgb(.surface, .light) == RGB(hex: 0xFFFFFF))
        #expect(Palette.rgb(.border, .light) == RGB(hex: 0xE7EDF3))
        #expect(Palette.rgb(.text, .light) == RGB(hex: 0x002244))
        #expect(Palette.rgb(.secondaryText, .light) == RGB(hex: 0x586E84))
        #expect(Palette.rgb(.accent, .light) == RGB(hex: 0x0071BC))
        #expect(Palette.rgb(.decoration, .light) == RGB(hex: 0x009FDA))
    }

    @Test func hexBecomesChannelsFromZeroToOne() {
        let color = RGB(hex: 0xFF8000)

        #expect(color.red == 1)
        #expect(abs(color.green - 128.0 / 255) < 1e-9)
        #expect(color.blue == 0)
    }

    @Test(arguments: ColorRole.allCases)
    func darkModeHasItsOwnColors(role: ColorRole) {
        #expect(Palette.rgb(role, .dark) != Palette.rgb(role, .light))
    }

    @Test(arguments: [(UIUserInterfaceStyle.light, UIAccessibilityContrast.normal, ColorMode.light),
                      (.dark, .normal, .dark),
                      (.light, .high, .lightHighContrast),
                      (.dark, .high, .darkHighContrast),
                      (.unspecified, .unspecified, .light)])
    func thePhoneSettingsPickTheMode(style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast,
                                     mode: ColorMode) {
        #expect(ColorMode(traits: Self.traits(style, contrast)) == mode)
    }

    @Test(arguments: ColorRole.allCases, ColorMode.allCases)
    func theColorOnScreenIsTheTableValue(role: ColorRole, mode: ColorMode) {
        let traits = Self.traits(mode.isDark ? .dark : .light, mode.isHighContrast ? .high : .normal)

        let shown = UIColor(Color(role)).resolvedColor(with: traits)

        #expect(RGB(shown) == Palette.rgb(role, mode))
    }

    private static func traits(_ style: UIUserInterfaceStyle,
                               _ contrast: UIAccessibilityContrast) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        }
    }
}

private extension RGB {
    /// Read back what UIKit resolved, rounded to the 8-bit value it came from.
    init(_ color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        self.init(hex: byte(red) << 16 | byte(green) << 8 | byte(blue))
    }
}
