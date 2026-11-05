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

    /// #123: the logo, a line and our airplane above the app's name.
    @Test(arguments: Look.allCases)
    func theHomeTitleIsOnTheThemeBackground(look: Look) throws {
        try check(HomeTitle().padding(24).frame(maxHeight: .infinity, alignment: .top).fieldScreen(),
                  look: look, name: "home")
    }

    @Test(arguments: Look.allCases)
    func thePrivacyCoverIsOnTheThemeBackground(look: Look) throws {
        try check(PrivacyCover(), look: look, name: "cover")
    }

    @Test(arguments: Look.allCases)
    func theMissionListIsOnTheThemeBackground(look: Look) throws {
        // The cards without the ScrollView and NavigationStack around them: ImageRenderer draws neither.
        // Full height as in the ScrollView, so the largest text wraps instead of being cut; the bottom is clipped.
        let image = try check(MissionCards(rows: Self.sampleRows, message: nil, words: MissionWordsTests.words)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top).fieldScreen(), look: look, name: "missions")

        // 20 pt in from the first card's left edge, 6 pt below its top: the card's own surface.
        #expect(Pixel.rgb(image, column: 72, row: 44) == Palette.rgb(.surface, look.mode))
    }

    /// #104: a busy server, on the list and on a mission whose download waits for it.
    @Test(arguments: Look.allCases)
    func aBusyServerIsShownOnTheThemeBackground(look: Look) throws {
        let rows = [
            MissionRow(id: "b", title: "Kandor Bridges", status: .paused(.busy(120)), pack: nil,
                       updateAvailable: false, canDownload: false, note: nil),
            MissionRow(id: "a", title: "Kandor Rural Roads Project, Package 1",
                       status: .ready(updated: MissionWordsTests.nov3), pack: Self.sampleRows.first?.pack,
                       updateAvailable: true, canDownload: false, note: MissionRow.text(.paused(.slowDown(30))))
        ]
        try check(MissionCards(rows: rows, message: MissionRow.serverBusy, words: MissionWordsTests.words)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top).fieldScreen(), look: look, name: "missions-busy")
    }

    @Test(arguments: Look.allCases)
    func thePackSummaryIsOnTheThemeBackground(look: Look) throws {
        let pack = try #require(Self.sampleRows.first?.pack)
        let title = "Kandor Rural Roads Project, Package 1"
        try check(PackSummary(title: title, pack: pack, words: MissionWordsTests.words)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top).fieldScreen(), look: look, name: "pack")
    }

    /// Fictional Kandor missions in the states a person meets most.
    static let sampleRows: [MissionRow] = {
        let nov3 = MissionWordsTests.nov3, nov10 = MissionWordsTests.nov10
        let pack = PackFacts(version: 3, files: 12, bytes: 48_000, projectRef: "KN-RR-001", published: nov3,
                             downloaded: nov3, expires: nov3.addingTimeInterval(60 * 86_400),
                             checklist: ChecklistSummary(questions: 9, french: true))
        return [
            MissionRow(id: "a", title: "Kandor Rural Roads Project, Package 1", status: .ready(updated: nov3),
                       pack: pack, updateAvailable: false, canDownload: false, note: nil),
            MissionRow(id: "b", title: "Kandor Bridges", status: .downloading(done: 1_200_000, total: 3_400_000),
                       pack: nil, updateAvailable: false, canDownload: false, note: nil),
            MissionRow(id: "c", title: "Kandor Water Supply", status: .expiring(updated: nov3, expires: nov10),
                       pack: pack, updateAvailable: true, canDownload: true, note: nil),
            MissionRow(id: "d", title: "Kandor Rural Clinics", status: .notDownloaded(available: true), pack: nil,
                       updateAvailable: false, canDownload: true, note: nil)
        ]
    }()

    @discardableResult
    private func check(_ view: some View, look: Look, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view  // a view taller than the phone is cut at the bottom
            .frame(width: Self.phone.width, height: Self.phone.height, alignment: .top)
            .environment(\.colorScheme, look.scheme)
            .environment(\.dynamicTypeSize, look.size))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)

        #expect(Pixel.rgb(image, column: 10, row: 10) == Palette.rgb(.background, look.mode))
        #expect(Self.drawsSomething(image, on: look), "only the background: the view was not drawn")
        if let folder = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"],
           let png = UIImage(cgImage: image).pngData() {
            try png.write(to: URL(filePath: folder).appending(path: "\(name)-\(look.rawValue).png"))
        }
        return image
    }

    /// Something other than the background somewhere on a 20 pixel grid (an empty picture fails).
    private static func drawsSomething(_ image: CGImage, on look: Look) -> Bool {
        let background = Palette.rgb(.background, look.mode)
        return stride(from: 0, to: image.height, by: 20).contains { row in
            stride(from: 0, to: image.width, by: 20).contains { Pixel.rgb(image, column: $0, row: row) != background }
        }
    }
}
