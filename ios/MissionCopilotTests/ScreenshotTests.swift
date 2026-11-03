import LocalAuthentication
import SwiftUI
import Testing
import UIKit
@testable import MissionCopilot

/// The real lock screen and privacy cover, drawn in light, dark and the largest text size (#87). Each
/// sits on the theme background. With SCREENSHOT_DIR set (TEST_RUNNER_SCREENSHOT_DIR for xcodebuild) the
/// images are saved for docs/design/theme.md; the system Face ID sheet hides them on a live screen.
@MainActor
struct ScreenshotTests {
    static let phone = CGSize(width: 430, height: 932)

    enum Look: String, CaseIterable {
        case light, dark, largestText

        var scheme: ColorScheme { self == .dark ? .dark : .light }
        var size: DynamicTypeSize { self == .largestText ? .accessibility5 : .large }
        var mode: ColorMode { self == .dark ? .dark : .light }
    }

    @Test(arguments: Look.allCases)
    func theLockScreenIsOnTheThemeBackground(look: Look) throws {
        let session = AppSession(authenticator: AppSessionTests.FakeAuthenticator(.failure(LAError(.userCancel))),
                                 policy: AppLockPolicy()) { _ in throw LockError.failed }

        try check(LockScreen(session: session), look: look, name: "lock")
    }

    @Test(arguments: Look.allCases)
    func thePrivacyCoverIsOnTheThemeBackground(look: Look) throws {
        try check(PrivacyCover(), look: look, name: "cover")
    }

    private func check(_ view: some View, look: Look, name: String) throws {
        let renderer = ImageRenderer(content: view
            .frame(width: Self.phone.width, height: Self.phone.height)
            .environment(\.colorScheme, look.scheme)
            .environment(\.dynamicTypeSize, look.size))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)

        #expect(Pixel.rgb(image, column: 10, row: 10) == Palette.rgb(.background, look.mode))
        if let folder = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"],
           let png = UIImage(cgImage: image).pngData() {
            try png.write(to: URL(filePath: folder).appending(path: "\(name)-\(look.rawValue).png"))
        }
    }
}
