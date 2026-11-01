// swift-tools-version: 6.0
// Offline speech spike (#14): scoring by code. Word error rate after normalization, and a separate score
// for the key facts (numbers and units), against the answer key built from the demo dataset.
// The speech engines themselves run on the iPhone only (AI Lab app); this package stays light for CI.
import PackageDescription

let package = Package(
    name: "SpeechLab",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "SpeechLab", targets: ["SpeechLab"])],
    targets: [
        .target(name: "SpeechLab"),
        .testTarget(name: "SpeechLabTests", dependencies: ["SpeechLab"]),
    ]
)
