// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SelectionActions",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SelectionActions", targets: ["SelectionActions"])
    ],
    targets: [
        .target(name: "SelectionActions"),
        .testTarget(name: "SelectionActionsTests", dependencies: ["SelectionActions"]),
    ]
)
