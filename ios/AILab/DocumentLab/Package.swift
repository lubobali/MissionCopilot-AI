// swift-tools-version: 6.0
// Document scanning spike (#15): Apple Vision reads invoices and reports (text and tables), on device,
// and code scores the result against the answer key built from the demo dataset.
import PackageDescription

let package = Package(
    name: "DocumentLab",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "DocumentLab", targets: ["DocumentLab"])],
    targets: [
        .target(name: "DocumentLab"),
        .testTarget(name: "DocumentLabTests", dependencies: ["DocumentLab"]),
    ]
)
