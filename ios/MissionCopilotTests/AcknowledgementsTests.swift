import Foundation
import Testing
@testable import MissionCopilot

/// SQLCipher's license asks for its text to be reproduced in the app; GRDB's (MIT) too (#68). The
/// texts ship inside the app and the Licenses screen shows them.
struct AcknowledgementsTests {
    @Test func theAppShipsTheLicenseOfEveryLinkedLibrary() throws {
        let licenses = try Acknowledgement.all(in: .main)

        #expect(Array(licenses.map(\.name).prefix(3)) == ["GRDB", "SQLCipher", "LFM2.5"])
        #expect(licenses.count == 15)
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

    @Test func theModelsLibrariesComeWithEveryLicenseTheyInclude() throws {
        // #136: one file per library in the parts list; MLX Swift's includes the C++ libraries inside it.
        let all = try Acknowledgement.all(in: .main)
        let text = { (name: String) -> String in all.first { $0.name == name }?.text ?? "" }

        #expect(text("mlx-swift-lm").contains("ml-explore"))
        #expect(text("mlx-swift").contains("Included in MLX Swift: fmt"))
        #expect(text("mlx-swift").contains("Included in MLX Swift: metal-cpp"))
        #expect(text("swift-transformers").contains("Apache License"))
        #expect(text("swift-collections").contains("Runtime Library Exception"))
        #expect(text("EventSource").contains("Mattt"))
        #expect(text("yyjson").contains("YaoYuan"))
    }

    @Test func aMissingLicenseIsAnErrorNotAnEmptyScreen() {
        #expect(throws: Acknowledgement.Missing(name: "GRDB")) {
            try Acknowledgement.all(in: Bundle(for: BundleToken.self))
        }
    }
}

private final class BundleToken {}
