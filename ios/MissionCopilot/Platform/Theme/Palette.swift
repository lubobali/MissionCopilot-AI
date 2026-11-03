import SwiftUI
import UIKit

/// What a color is for. Screens ask for a role, never for a raw color, so every color on screen comes
/// from this table and the contrast test covers it (#87).
enum ColorRole: CaseIterable, Sendable {
    case background, surface, border
    case text, secondaryText
    case accent, onAccent
    case success, warning, danger
    /// Lines and fills only: too faint to read as text on a light background (3.0:1 on white).
    case decoration
}

/// Light or dark, with or without the phone's Increase Contrast setting.
enum ColorMode: CaseIterable, Sendable {
    case light, dark, lightHighContrast, darkHighContrast

    init(traits: UITraitCollection) {
        let dark = traits.userInterfaceStyle == .dark
        let high = traits.accessibilityContrast == .high
        self = switch (dark, high) {
        case (false, false): .light
        case (true, false): .dark
        case (false, true): .lightHighContrast
        case (true, true): .darkHighContrast
        }
    }

    var isDark: Bool { self == .dark || self == .darkHighContrast }
    var isHighContrast: Bool { self == .lightHighContrast || self == .darkHighContrast }
}

/// An sRGB color, each channel from 0 to 1.
struct RGB: Equatable, Sendable {
    let red: Double, green: Double, blue: Double

    init(hex: UInt32) {
        red = Double(hex >> 16 & 0xFF) / 255
        green = Double(hex >> 8 & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }
}

/// Field Navy: a calm navy and blue palette, readable outdoors. Increased contrast keeps every text pair
/// at 7:1 or more.
enum Palette {
    static func rgb(_ role: ColorRole, _ mode: ColorMode) -> RGB {
        let row = row(role)
        let hex = switch mode {
        case .light: row.light
        case .dark: row.dark
        case .lightHighContrast: row.lightHigh
        case .darkHighContrast: row.darkHigh
        }
        return RGB(hex: hex)
    }

    private struct Row {
        let light: UInt32, dark: UInt32, lightHigh: UInt32, darkHigh: UInt32
    }

    // A switch, so the compiler proves every role has all four values. One case per role is a table,
    // not branching logic.
    // swiftlint:disable:next cyclomatic_complexity
    private static func row(_ role: ColorRole) -> Row {
        switch role {
        case .background: Row(light: 0xF5F7F9, dark: 0x0B1220, lightHigh: 0xFFFFFF, darkHigh: 0x000000)
        case .surface: Row(light: 0xFFFFFF, dark: 0x121A2B, lightHigh: 0xFFFFFF, darkHigh: 0x0B1220)
        case .border: Row(light: 0xE7EDF3, dark: 0x24304A, lightHigh: 0x586E84, darkHigh: 0x8AA0B6)
        case .text: Row(light: 0x002244, dark: 0xF5F7F9, lightHigh: 0x001126, darkHigh: 0xFFFFFF)
        case .secondaryText: Row(light: 0x586E84, dark: 0x8AA0B6, lightHigh: 0x3E5266, darkHigh: 0xC2D0DD)
        case .accent: Row(light: 0x0071BC, dark: 0x4DA3E0, lightHigh: 0x005A96, darkHigh: 0x8CC8F0)
        case .onAccent: Row(light: 0xFFFFFF, dark: 0x0B1220, lightHigh: 0xFFFFFF, darkHigh: 0x000000)
        case .success: Row(light: 0x1B7A3A, dark: 0x5CC27A, lightHigh: 0x0F5C2A, darkHigh: 0x8EDDA4)
        case .warning: Row(light: 0x8A5300, dark: 0xF2B84B, lightHigh: 0x6B4000, darkHigh: 0xFFD285)
        case .danger: Row(light: 0xB3261E, dark: 0xFF8A80, lightHigh: 0x8C1D17, darkHigh: 0xFFB3AD)
        case .decoration: Row(light: 0x009FDA, dark: 0x33B5E5, lightHigh: 0x0071BC, darkHigh: 0x66CBEF)
        }
    }
}

extension Color {
    /// A color that follows the phone's light, dark and contrast settings.
    init(_ role: ColorRole) {
        self.init(uiColor: UIColor { traits in
            let rgb = Palette.rgb(role, ColorMode(traits: traits))
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    }
}
