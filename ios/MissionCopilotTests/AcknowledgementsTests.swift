import Foundation
import Testing
@testable import MissionCopilot

/// SQLCipher's license asks for its text to be reproduced in the app; GRDB's (MIT) too (#68). The
/// texts ship inside the app and the Licenses screen shows them.
struct AcknowledgementsTests {
    @Test func theAppShipsTheLicenseOfEveryLinkedLibrary() throws {
        let licenses = try Acknowledgement.all(in: .main)

        #expect(licenses.map(\.name) == ["GRDB", "SQLCipher", "LFM2.5"])
        #expect(licenses[0].text.contains("Gwendal Rou"))
        #expect(licenses[1].text.contains("ZETETIC LLC"))
    }

    @Test func theModelInsideTheAppComesWithItsLicenseAndTheNoticeThatItWasConverted() throws {
        // The LFM Open License v1.0 (Section 4) asks for its text with every copy, and for a notice
        // on changed files: the app ships mlx-community's 4-bit conversion (#125).
        let model = try #require(try Acknowledgement.all(in: .main).first { $0.name == "LFM2.5" })

        #expect(model.text.contains("LFM Open License v1.0"))
        #expect(model.text.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"))
        #expect(model.text.contains("4-bit"))
        #expect(model.text.contains("mlx-community"))
    }

    @Test func aMissingLicenseIsAnErrorNotAnEmptyScreen() {
        #expect(throws: Acknowledgement.Missing(name: "GRDB")) {
            try Acknowledgement.all(in: Bundle(for: BundleToken.self))
        }
    }
}

private final class BundleToken {}
