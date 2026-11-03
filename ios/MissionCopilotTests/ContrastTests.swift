import Testing
@testable import MissionCopilot

/// Every text color is readable on every background it is used on, in every mode (WCAG 2.2, #87).
struct ContrastTests {
    @Test func blackOnWhiteIsTwentyOneToOne() {
        #expect(abs(Contrast.ratio(RGB(hex: 0x000000), RGB(hex: 0xFFFFFF)) - 21) < 1e-9)
    }

    @Test func theOrderOfTheTwoColorsDoesNotMatter() {
        let navy = RGB(hex: 0x002244), white = RGB(hex: 0xFFFFFF)

        #expect(Contrast.ratio(navy, white) == Contrast.ratio(white, navy))
    }

    @Test func knownPairsMatchTheWCAGFormula() {
        let white = RGB(hex: 0xFFFFFF)

        #expect(abs(Contrast.ratio(RGB(hex: 0x0071BC), white) - 5.14) < 0.01)
        #expect(abs(Contrast.ratio(RGB(hex: 0x009FDA), white) - 3.01) < 0.01)
        #expect(abs(Contrast.ratio(RGB(hex: 0x777777), white) - 4.48) < 0.01)
        #expect(abs(Contrast.ratio(RGB(hex: 0x0A0A0A), white) - 19.80) < 0.01)  // very dark: linear part
    }

    @Test func normalModesNeedAAAndIncreasedContrastNeedsAAA() {
        #expect(Contrast.required(.light) == 4.5)
        #expect(Contrast.required(.dark) == 4.5)
        #expect(Contrast.required(.lightHighContrast) == 7)
        #expect(Contrast.required(.darkHighContrast) == 7)
    }

    @Test(arguments: ColorMode.allCases)
    func everyTextPairIsReadable(mode: ColorMode) {
        for pair in Palette.textPairs {
            let ratio = Contrast.ratio(Palette.rgb(pair.text, mode), Palette.rgb(pair.on, mode))
            #expect(ratio >= Contrast.required(mode), "\(pair.text) on \(pair.on) in \(mode): \(ratio)")
        }
    }

    @Test func everyRoleThatCanBeTextIsChecked() {
        let text: Set<ColorRole> = [.text, .secondaryText, .accent, .onAccent, .success, .warning, .danger]

        #expect(Set(Palette.textPairs.map(\.text)) == text)
    }

    @Test func textIsCheckedOnBothBackgrounds() {
        for role in [ColorRole.text, .secondaryText, .accent, .success, .warning, .danger] {
            #expect(Palette.textPairs.contains { $0.text == role && $0.on == .background })
            #expect(Palette.textPairs.contains { $0.text == role && $0.on == .surface })
        }
        #expect(Palette.textPairs.contains { $0.text == .onAccent && $0.on == .accent })
    }

    @Test func theCyanIsNeverText() {
        #expect(!Palette.textPairs.contains { $0.text == .decoration })
        // Why: on the light background it is too faint to read.
        #expect(Contrast.ratio(Palette.rgb(.decoration, .light), Palette.rgb(.background, .light)) < 4.5)
    }
}
