// swift-tools-version: 6.0
// Encryption spike (#16): SQLCipher database, Keychain key, per-mission key wrap, crypto-shred.
// Simulator-testable logic lives here; the AI Lab app uses it for the on-device proofs.
import PackageDescription

let package = Package(
    name: "EncryptionLab",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "EncryptionLab", targets: ["EncryptionLab"])],
    dependencies: [
        // Our GRDB 7.12.0 fork with SQLCipher 4.20.0 (exact); only Package.swift differs from upstream.
        .package(url: "https://github.com/lubobali/GRDB.swift.git", revision: "743e132654bb30469ce64e2294e14d8ad0aa4d95"),
    ],
    targets: [
        .target(name: "EncryptionLab", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "EncryptionLabTests", dependencies: ["EncryptionLab"]),
    ]
)
