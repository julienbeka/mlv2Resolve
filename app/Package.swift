// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "MLVSwitchCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MLVSwitchCore", targets: ["MLVSwitchCore"]),
    ],
    targets: [
        .target(name: "MLVSwitchCore"),
        .testTarget(name: "MLVSwitchCoreTests", dependencies: ["MLVSwitchCore"]),
    ]
)
