import Foundation
import Testing
@testable import MissionCopilot

/// SQLCipher's license asks for its text to be reproduced in the app; GRDB's (MIT) too (#68). The
/// texts ship inside the app and the Licenses screen shows them.
struct AcknowledgementsTests {
    @Test func theAppShipsTheLicenseOfEveryLinkedLibrary() throws {
        let licenses = try Acknowledgement.all(in: .main)

        #expect(licenses.map(\.name) == ["GRDB", "SQLCipher"])
        #expect(licenses[0].text.contains("Gwendal Rou"))
        #expect(licenses[1].text.contains("ZETETIC LLC"))
    }

    @Test func aMissingLicenseIsAnErrorNotAnEmptyScreen() {
        #expect(throws: Acknowledgement.Missing(name: "GRDB")) {
            try Acknowledgement.all(in: Bundle(for: BundleToken.self))
        }
    }
}

private final class BundleToken {}
