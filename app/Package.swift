// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "MLV2ResolveCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MLV2ResolveCore", targets: ["MLV2ResolveCore"]),
    ],
    targets: [
        .target(name: "MLV2ResolveCore", resources: [.process("Resources")]),
        .testTarget(name: "MLV2ResolveCoreTests", dependencies: ["MLV2ResolveCore"]),
    ]
)
