import Testing
@testable import MissionCopilot

/// The document scan's outcome in words (#138, step 6.5.1). The scanner itself is Apple's document camera,
/// presented full screen straight from the app's top view controller (never inside a navigation stack or a
/// sheet: iOS 26 can crash there, Apple forums 811188); it is proven on the iPhone, not here.
struct DocumentScanTests {
    @Test(arguments: [
        (ScanOutcome.pages(1), "1 page scanned"),
        (.pages(3), "3 pages scanned"),
        (.cancelled, "No pages scanned"),
        (.unavailable, "This iPhone cannot scan documents. Take a photo of each page instead."),
        (.failed, "The scan did not finish. Try again.")
    ])
    func eachOutcomeSaysWhatHappened(outcome: ScanOutcome, words: String) {
        #expect(outcome.words == words)
    }

    @Test func onlyPagesCountAsAScan() {
        #expect(ScanOutcome.pages(2).scanned)
        #expect(!ScanOutcome.cancelled.scanned)
        #expect(!ScanOutcome.failed.scanned)
    }
}
