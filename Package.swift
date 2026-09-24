// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ReBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ReBar")
    ]
)
