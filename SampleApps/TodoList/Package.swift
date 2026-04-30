// swift-tools-version: 6.0
//
// TodoList — a deliberately simple Swift package used as a regression fixture
// for slopguard-swift. Every method here is short, every code path is tested,
// and the package's `swift test` run produces near-100% line coverage. Running
// slopguard-swift against this directory should *always* report zero crappy
// methods — any drift from that baseline points at a regression in the
// analyzer (complexity counter, coverage join, aggregator) rather than the
// fixture itself.
//
// The fixture is a standalone package with its own dependency graph (none),
// so it is intentionally NOT a target of the main slopguard-swift package.
// Build / test it from this directory.

import PackageDescription

let package = Package(
    name: "TodoList",
    products: [
        .library(name: "TodoList", targets: ["TodoList"])
    ],
    targets: [
        .target(
            name: "TodoList",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TodoListTests",
            dependencies: ["TodoList"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
