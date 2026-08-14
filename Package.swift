// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpendGovernor",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SpendGovernor", targets: ["SpendGovernor"]),
        .library(name: "SpendGovernorUI", targets: ["SpendGovernorUI"])
    ],
    targets: [
        .target(name: "SpendGovernor"),
        .target(name: "SpendGovernorUI", dependencies: ["SpendGovernor"]),
        .testTarget(name: "SpendGovernorTests", dependencies: ["SpendGovernor"])
    ]
)
