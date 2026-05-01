// swift-tools-version: 6.0
//
// slopguard-swift — CRAP guardrail for Swift / iOS.
//
// Targets:
//   • SlopguardCore     — Pure analysis logic: CRAP formula, models, ComplexityVisitor.
//   • SlopguardCoverage — Xcode coverage parsing via `xcrun xccov`.
//   • SlopguardCLI      — ArgumentParser CLI (analyze / version).
//   • slopguard-bin     — Thin executable entry point.

import PackageDescription

let package = Package(
    name: "slopguard-swift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SlopguardCore", targets: ["SlopguardCore"]),
        .library(name: "SlopguardCoverage", targets: ["SlopguardCoverage"]),
        .library(name: "SlopguardCLI", targets: ["SlopguardCLI"]),
        .executable(name: "slopguard-swift", targets: ["slopguard-bin"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // MARK: Core
        .target(
            name: "SlopguardCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ],
            path: "Sources/slopguard-core",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Coverage
        .target(
            name: "SlopguardCoverage",
            dependencies: ["SlopguardCore"],
            path: "Sources/slopguard-coverage",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: CLI library
        // Lives as a library so that:
        //   1. `SlopguardCLITests` can `@testable import SlopguardCLI`
        //      (xcodebuild rejects testable-imports of executable targets,
        //      and slopguard's own auto-coverage path uses xcodebuild test).
        //   2. The actual entry point is a tiny shim in `slopguard-bin`.
        .target(
            name: "SlopguardCLI",
            dependencies: [
                "SlopguardCore",
                "SlopguardCoverage",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/slopguard-cli",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: CLI executable shim
        .executableTarget(
            name: "slopguard-bin",
            dependencies: ["SlopguardCLI"],
            path: "Sources/slopguard-cli-bin",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Tests
        .testTarget(
            name: "SlopguardCoreTests",
            dependencies: ["SlopguardCore"],
            path: "Tests/SlopguardCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SlopguardCoverageTests",
            dependencies: ["SlopguardCoverage"],
            path: "Tests/SlopguardCoverageTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SlopguardCLITests",
            dependencies: ["SlopguardCLI"],
            path: "Tests/SlopguardCLITests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
