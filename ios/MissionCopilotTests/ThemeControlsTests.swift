import SwiftUI
import Testing
@testable import MissionCopilot

/// Controls are easy to hit with a thumb outdoors, and a status is never told by color alone (#87).
@MainActor
struct ThemeControlsTests {
    @Test func thePrimaryButtonIsAtLeast48PointsHigh() {
        let button = Button("Unlock") {}.buttonStyle(.fieldPrimary)

        #expect(Self.height(of: button) >= 48)
    }

    @Test func theSecondaryButtonIsAtLeast44PointsHigh() {
        let button = Button("Licenses") {}.buttonStyle(.fieldSecondary)

        #expect(Self.height(of: button) >= 44)
    }

    @Test func thePrimaryButtonUsesTheAccentAndItsReadableText() {
        #expect(FieldPrimaryButtonStyle.fill == .accent)
        #expect(FieldPrimaryButtonStyle.label == .onAccent)
    }

    @Test func thePrimaryButtonIsReallyFilledWithTheAccent() throws {
        let image = try #require(ImageRenderer(content: Button("Unlock") {}.buttonStyle(.fieldPrimary)
            .frame(width: 300)).cgImage)

        // Left edge, half way down: inside the rounded fill, away from the words.
        #expect(Self.pixel(image, column: 8, row: image.height / 2) == Palette.rgb(.accent, .light))
    }

    @Test func theStatusLabelShowsWordsNotJustAnIcon() {
        let label = Self.width(of: StatusLabel(kind: .ready))
        let icon = Self.width(of: Image(systemName: StatusKind.ready.icon).font(.subheadline.weight(.semibold)))

        #expect(label > icon + 40)
    }

    @Test func theHeroIconGrowsWithTheTextSize() {
        let small = Self.height(of: HeroIcon(systemName: "lock.fill").environment(\.dynamicTypeSize, .large))
        let large = Self.height(of: HeroIcon(systemName: "lock.fill").environment(\.dynamicTypeSize, .accessibility3))

        #expect(large > small)
    }

    @Test(arguments: StatusKind.allCases)
    func everyStatusHasAnIconAndWords(kind: StatusKind) {
        #expect(!kind.words.isEmpty)
        #expect(UIImage(systemName: kind.icon) != nil, "\(kind.icon) is not an SF Symbol")
    }

    @Test func everyStatusHasItsOwnIconAndWords() {
        let kinds = StatusKind.allCases

        #expect(Set(kinds.map(\.icon)).count == kinds.count)
        #expect(Set(kinds.map(\.words)).count == kinds.count)
    }

    @Test(arguments: StatusKind.allCases)
    func everyStatusColorIsAReadableTextRole(kind: StatusKind) {
        #expect(Palette.textPairs.contains { $0.text == kind.color })
    }

    @Test func statusesSayWhatTheOfficerNeedsToKnow() {
        #expect(StatusKind.ready.words == "Ready for offline")
        #expect(StatusKind.paused.words == "Paused, waiting for connection")
        #expect(StatusKind.notDownloaded.words == "Not downloaded")
        #expect(StatusKind.ready.color == .success)
        #expect(StatusKind.expired.color == .danger)
    }

    private static func width(of view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage?.size.width ?? 0
    }

    /// The color of one pixel, read by drawing the image into a known RGB buffer.
    private static func pixel(_ image: CGImage, column: Int, row: Int) -> RGB? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: -column, y: row - image.height + 1, width: image.width, height: image.height))
        return RGB(hex: UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2]))
    }

    private static func height(of view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage?.size.height ?? 0
    }
}
