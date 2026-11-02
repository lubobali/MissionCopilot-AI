import Foundation
import SwiftUI

/// The open-source libraries inside the app and their license texts, shipped as files (#68).
/// SQLCipher's license asks for its text in the app; GRDB's MIT license asks for its notice.
struct Acknowledgement: Equatable, Identifiable {
    struct Missing: Error, Equatable { let name: String }

    static let libraries = ["GRDB", "SQLCipher"]

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
                    .navigationTitle(license.name)
            }
        }
        .navigationTitle("Licenses")
    }
}
