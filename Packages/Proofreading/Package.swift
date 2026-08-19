// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Proofreading",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Proofreading", targets: ["Proofreading"])
    ],
    dependencies: [
        .package(path: "../AutocompleteCore")
    ],
    targets: [
        .target(
            name: "Proofreading",
            dependencies: [
                .product(name: "AutocompleteCore", package: "AutocompleteCore")
            ]
        ),
        .testTarget(
            name: "ProofreadingTests",
            dependencies: [
                "Proofreading",
                .product(name: "AutocompleteCore", package: "AutocompleteCore")
            ]
        )
    ]
)
