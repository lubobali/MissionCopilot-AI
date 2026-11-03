import SwiftUI
import Testing
import UIKit
@testable import MissionCopilot

/// The developer's logo is in the app, the launch screen shows it, and the launch color is the theme's
/// background (#87). The tests run inside the app, so Bundle.main is the app itself.
struct BrandTests {
    @Test func theLogoShipsInTheApp() {
        #expect(UIImage(named: LogoMark.imageName) != nil)
    }

    @Test func theLaunchScreenShowsTheLogoOnTheBackground() throws {
        let launch = try #require(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen") as? [String: Any])

        #expect(launch["UIImageName"] as? String == LogoMark.imageName)
        #expect(launch["UIColorName"] as? String == "LaunchBackground")
    }

    @Test(arguments: [(UIUserInterfaceStyle.light, ColorMode.light), (.dark, .dark)])
    func theLaunchColorIsTheThemeBackground(style: UIUserInterfaceStyle, mode: ColorMode) throws {
        let color = try #require(UIColor(named: "LaunchBackground"))
        let shown = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        shown.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let expected = Palette.rgb(.background, mode)

        #expect(abs(red - expected.red) < 0.002 && abs(green - expected.green) < 0.002
                && abs(blue - expected.blue) < 0.002)
    }

    @Test func theAppHasAnIcon() {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]

        #expect(primary?["CFBundleIconName"] as? String == "AppIcon")
    }

    @MainActor
    @Test func theLogoMarkGrowsWithTheTextSize() {
        func height(_ size: DynamicTypeSize) -> CGFloat {
            let renderer = ImageRenderer(content: LogoMark().environment(\.dynamicTypeSize, size))
            renderer.scale = 1
            return renderer.uiImage?.size.height ?? 0
        }

        #expect(height(.large) >= 96)
        #expect(height(.accessibility3) > height(.large))
    }
}
