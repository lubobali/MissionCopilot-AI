import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import MissionCopilot

/// The bad-crop warning (#138, step 6.5.4; spike #15's change): in the darkest Phase 2 run the scanner caught
/// the whole monitor, and the model, given the extra text, returned "0 of 0 km". Found while testing: Vision
/// calls the whole image the page even when other windows' text surrounds it, so "outside Vision's page"
/// never fires. A cropped page has margins; a caught screen has text at its very edge. So a page looks
/// cropped wrong when a line of text touches the image's edge band, or Vision's page covers under half of it.
@MainActor
struct PageLayoutTests {
    @Test(arguments: [(0.95, 0, false), (0.49, 0, true), (0.5, 0, false), (0.95, 1, true)])
    func theRule(area: Double, atTheEdge: Int, cropped: Bool) {
        #expect(PageLayout(documentArea: area, linesAtTheEdge: atTheEdge).looksCropped == cropped)
    }

    @Test func aLineCountsOnlyWhenItReachesTheEdgeBand() {
        let page = CGRect(x: 0, y: 0, width: 1, height: 1)
        let inside = CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.02)
        let nearTheEdge = CGRect(x: 0.03, y: 0.5, width: 0.3, height: 0.02)  // starts at 3%: a margin
        let atTheLeft = CGRect(x: 0.01, y: 0.5, width: 0.3, height: 0.02)
        let atTheTop = CGRect(x: 0.4, y: 0.985, width: 0.2, height: 0.01)

        let layout = PageLayout(page: page, lines: [inside, nearTheEdge, atTheLeft, atTheTop])

        #expect(layout.linesAtTheEdge == 2)
        #expect(layout.documentArea == 1)
    }

    @Test(arguments: ["invoice-14", "progress-report-2026-09"])
    func aCleanDemoPageIsNotFlagged(name: String) async throws {
        let reading = try await PageReading.read(try #require(try PageReadingTests.demo(name).pngData()))

        let layout = try #require(reading.layout)
        #expect(!layout.looksCropped, "\(layout)")
    }

    @Test func aPageCaughtWithTheScreenAroundItIsFlagged() async throws {
        // The demo invoice at half size in the middle of a "screen", with other windows' text around it.
        let page = try PageReadingTests.demo("invoice-14")
        let size = CGSize(width: page.size.width * 2, height: page.size.height * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let screen = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            page.draw(in: CGRect(x: size.width * 0.3, y: size.height * 0.3, width: size.width * 0.4,
                                 height: size.height * 0.4))
            let font = UIFont.systemFont(ofSize: size.width / 40)
            for (text, point) in [("Inbox - Mail - 3 unread", CGPoint(x: 40, y: 40)),
                                  ("Calendar: team meeting at 10:00", CGPoint(x: 40, y: size.height - 120)),
                                  ("Notes - shopping list", CGPoint(x: size.width * 0.72, y: size.height * 0.5))] {
                (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: UIColor.black])
            }
        }

        let reading = try await PageReading.read(try #require(screen.pngData()))

        let layout = try #require(reading.layout)
        #expect(layout.looksCropped, "\(layout)")
    }
}
