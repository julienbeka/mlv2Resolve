// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "MLV2DNGCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MLV2DNGCore", targets: ["MLV2DNGCore"]),
    ],
    targets: [
        .target(name: "MLV2DNGCore", resources: [.process("Resources")]),
        .testTarget(name: "MLV2DNGCoreTests", dependencies: ["MLV2DNGCore"], resources: [.copy("Fixtures")]),
    ]
)
