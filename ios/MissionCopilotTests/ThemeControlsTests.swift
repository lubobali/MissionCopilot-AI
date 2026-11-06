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
        #expect(Pixel.rgb(image, column: 8, row: image.height / 2) == Palette.rgb(.accent, .light))
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
        #expect(StatusKind.paused.words == "Paused")
        #expect(StatusKind.notDownloaded.words == "Not downloaded")
        #expect(StatusKind.ready.color == .success)
        #expect(StatusKind.expired.color == .danger)
    }

    private static func width(of view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage?.size.width ?? 0
    }

    private static func height(of view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage?.size.height ?? 0
    }
}

/// A switched-off button looks switched off (found on the iPhone, #129: Retake photo stayed bright on a
/// finished, locked walk).
@MainActor
struct DisabledButtonTests {
    private func pixel(_ button: some View) throws -> RGB {
        let renderer = ImageRenderer(content: button.frame(width: 240, height: 60).background(Color(.background)))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return try #require(Pixel.rgb(image, column: 120, row: 30))
    }

    @Test func aDisabledPrimaryButtonIsDimmed() throws {
        let enabled = try pixel(Button(" ") {}.buttonStyle(.fieldPrimary))
        let disabled = try pixel(Button(" ") {}.buttonStyle(.fieldPrimary).disabled(true))

        #expect(enabled == Palette.rgb(.accent, .light))
        #expect(disabled != enabled)
    }

    @Test func aDisabledSecondaryButtonIsDimmed() throws {
        let label = String(repeating: "█", count: 12)
        let enabled = try pixel(Button(label) {}.buttonStyle(.fieldSecondary))
        let disabled = try pixel(Button(label) {}.buttonStyle(.fieldSecondary).disabled(true))

        #expect(disabled != enabled)
    }

    @Test func aDisabledButtonThroughTheRunTimeStyleIsDimmed() throws {
        // Retake photo goes through AnyButtonStyle: the fade must survive the wrapper.
        let label = String(repeating: "█", count: 12)
        let enabled = try pixel(Button(label) {}.buttonStyle(AnyButtonStyle(.fieldSecondary)))
        let disabled = try pixel(Button(label) {}.buttonStyle(AnyButtonStyle(.fieldSecondary)).disabled(true))
        let primaryDisabled = try pixel(Button(" ") {}.buttonStyle(AnyButtonStyle(.fieldPrimary)).disabled(true))

        #expect(disabled != enabled)
        #expect(primaryDisabled != Palette.rgb(.accent, .light))
    }
}
