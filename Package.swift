// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LocationManager",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "LocationManager",
            targets: ["LocationManager"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "LocationManager",
            dependencies: [],
            path: "Sources/LocationManager"
        ),
        .testTarget(
            name: "LocationManagerTests",
            dependencies: ["LocationManager"],
            path: "Tests/LocationManagerTests"
        )
    ]
)
