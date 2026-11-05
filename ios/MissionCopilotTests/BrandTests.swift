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

        #expect(launch["UIImageName"] as? String == "LaunchLogo")
        #expect(UIImage(named: "LaunchLogo") != nil)
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
    @Test(arguments: [ColorScheme.light, .dark])
    func theLogoSitsOnAWhiteTileSoItReadsInDarkMode(scheme: ColorScheme) throws {
        let image = try #require(ImageRenderer(content: LogoMark().environment(\.colorScheme, scheme)).cgImage)

        // Left edge, half way down: inside the tile, outside the logo (like the app icon).
        #expect(Pixel.rgb(image, column: 3, row: image.height / 2) == RGB(hex: 0xFFFFFF))
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

    // MARK: The lockup on the home screen (#123)

    @Test func ourAirplaneShipsAsATemplateSoTheThemeColorsIt() throws {
        let airplane = try #require(UIImage(named: AirplaneMark.imageName))

        #expect(airplane.renderingMode == .alwaysTemplate)
    }

    @MainActor
    @Test(arguments: [(ColorScheme.light, ColorMode.light), (.dark, .dark)])
    func theLockupIsTheLogoTileALineAndTheAirplane(scheme: ColorScheme, mode: ColorMode) throws {
        let image = try Self.render(BrandLockup(), scheme: scheme, width: 382)
        let middle = image.height / 2

        #expect(image.width > image.height, "side by side at the normal text size")
        #expect(Pixel.rgb(image, column: 3, row: middle) == RGB(hex: 0xFFFFFF), "the logo's white tile first")
        let row = (0..<image.width).map { Pixel.rgb(image, column: $0, row: middle) }
        let line = try #require(row.firstIndex(of: Palette.rgb(.decoration, mode)), "a line in the theme's color")
        let airplane = (0..<image.width).flatMap { column in
            (0..<image.height).map { Pixel.rgb(image, column: column, row: $0) }
                .contains(Palette.rgb(.accent, mode)) ? [column] : []
        }
        #expect(try #require(airplane.min()) > line, "the airplane after the line, in the accent color")
    }

    @MainActor
    @Test func atTheLargestTextTheLockupStacksInsteadOfClipping() throws {
        let width = 382
        let image = try Self.render(BrandLockup().environment(\.dynamicTypeSize, .accessibility5),
                                    scheme: .light, width: CGFloat(width))

        #expect(image.width <= width, "never wider than the screen")
        #expect(image.height > image.width, "logo above, airplane below")
    }

    /// The view at 1x, offered `width` points like the home screen's column.
    @MainActor
    private static func render(_ view: some View, scheme: ColorScheme, width: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }
}
