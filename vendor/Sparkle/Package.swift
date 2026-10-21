// swift-tools-version:5.9
//
// Sparkle 2.10.0 (https://sparkle-project.org), the updater for apps outside the App
// Store, vendored as its official Swift Package Manager build: Sparkle.xcframework from
// Sparkle-for-Swift-Package-Manager.zip (sha256 17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec
// 6c371dbc07cdecd2a14fd959, as Sparkle's own Package.swift pins it), without its dSYMs,
// and bin/sign_update and bin/generate_keys for scripts/build-release.sh. Vendored, a
// build fetches nothing. MIT licensed: see LICENSE.
import PackageDescription

let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v12)],
    products: [.library(name: "Sparkle", targets: ["Sparkle"])],
    targets: [.binaryTarget(name: "Sparkle", path: "Sparkle.xcframework")]
)
