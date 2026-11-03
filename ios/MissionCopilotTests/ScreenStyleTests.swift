import SwiftUI
import Testing
@testable import MissionCopilot

/// A whole screen sits on the theme background and follows light and dark mode (#87).
@MainActor
struct ScreenStyleTests {
    @Test(arguments: [(ColorScheme.light, ColorMode.light), (.dark, .dark)])
    func aFieldScreenIsOnTheThemeBackground(scheme: ColorScheme, mode: ColorMode) throws {
        let screen = Text("Kandor").fieldScreen().frame(width: 200, height: 200)
            .environment(\.colorScheme, scheme)

        let image = try #require(ImageRenderer(content: screen).cgImage)

        #expect(Pixel.rgb(image, column: 4, row: 4) == Palette.rgb(.background, mode))
    }

    @Test func textOnAFieldScreenUsesTheThemeTextColor() throws {
        let screen = Rectangle().frame(width: 20, height: 20).fieldScreen()

        let image = try #require(ImageRenderer(content: screen).cgImage)

        // A shape with no color of its own takes the screen's foreground style.
        #expect(Pixel.rgb(image, column: 10, row: 10) == Palette.rgb(.text, .light))
    }
}
