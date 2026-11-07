import Foundation
import SwiftUI

/// The open-source libraries inside the app and their license texts, shipped as files (#68).
/// SQLCipher's license asks for its text in the app; GRDB's MIT license asks for its notice. The on-device
/// model's LFM Open License v1.0 asks for its text with every copy, and the model ships inside the app (#125).
struct Acknowledgement: Equatable, Identifiable {
    struct Missing: Error, Equatable { let name: String }

    /// Then the model's libraries (#136), one per entry of docs/sbom/app.cdx.json (a guard keeps them equal);
    /// mlx-swift's file includes the C++ libraries inside it.
    static let libraries = [
        "GRDB", "SQLCipher", "LFM2.5", "mlx-swift-lm", "mlx-swift", "swift-transformers", "swift-huggingface",
        "swift-jinja", "swift-collections", "swift-numerics", "swift-crypto", "swift-asn1", "swift-syntax",
        "EventSource", "yyjson"
    ]

    let name: String
    let text: String
    var id: String { name }

    static func all(in bundle: Bundle) throws -> [Acknowledgement] {
        try libraries.map { name in
            guard let url = bundle.url(forResource: "License-\(name)", withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { throw Missing(name: name) }
            return Acknowledgement(name: name, text: text)
        }
    }
}

struct AcknowledgementsView: View {
    private let licenses = (try? Acknowledgement.all(in: .main)) ?? []

    var body: some View {
        List(licenses) { license in
            NavigationLink(license.name) {
                ScrollView { Text(license.text).font(.footnote).padding() }
                    .fieldScreen()
                    .navigationTitle(license.name)
            }
        }
        .fieldList()
        .navigationTitle("Licenses")
    }
}
