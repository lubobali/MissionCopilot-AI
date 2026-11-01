import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Story #47 on the iPhone: how long the main app's model-signature check takes on the real 633 MB
/// model (the same ModelSignature.swift file), offline. The bundle is copied next to the model folder.
@MainActor @Observable
final class ModelSignatureLabModel {
    static let model = "LFM2.5-1.2B-Instruct-4bit"
    var log: [String] = ["Copies the model's .sig next to it first (by cable), then runs the check 3 times."]
    var running = false
    private var results: [String: String] = [:]

    func run() {
        running = true
        Task {
            await self.measure()
            self.save()
            self.running = false
        }
    }

    private func measure() async {
        record("network during run", await DeviceInfo.networkStatus())
        let folder = DeviceInfo.documents.appendingPathComponent(Self.model, isDirectory: true)
        let bundleURL = DeviceInfo.documents.appendingPathComponent("\(Self.model).sig")
        guard let bundle = try? Data(contentsOf: bundleURL) else {
            return record("bundle", "missing: copy \(Self.model).sig to Documents")
        }
        do {
            let key = try P256.Signing.PublicKey(pemRepresentation: ModelSigningKey.pem)
            for run in 1...3 {
                let start = Date()
                let files = try await Task.detached(priority: .userInitiated) {
                    try ModelSignature.verify(modelFolder: folder, bundle: bundle, publicKey: key)
                }.value
                record("run \(run)", String(format: "verified %d files in %.2f s, free memory %d MB",
                                            files.count, Date().timeIntervalSince(start), DeviceInfo.freeMemoryMB()))
            }
        } catch {
            record("verify", "REFUSED: \(error)")
        }
    }

    private func record(_ name: String, _ value: String) {
        results[name] = value
        log.append(name + ": " + value)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(results).write(to: DeviceInfo.documents.appendingPathComponent("model-signature-results.json"))
    }
}

struct ModelSignatureView: View {
    @State private var model = ModelSignatureLabModel()

    var body: some View {
        List {
            Section("OpenSSF signature of the real model") {
                Button("Verify the model 3 times") { model.run() }.disabled(model.running)
            }
            Section("Log") {
                ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
            }
        }
        .navigationTitle("Model signature #47")
    }
}
