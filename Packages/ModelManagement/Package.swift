// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ModelManagement",
    platforms: [.macOS(.v14)],
    products: [
        // Pure-Foundation model catalog + downloader + validator. No llama dependency, so it
        // unit-tests without the gitignored llama xcframework being present.
        .library(name: "ModelManagement", targets: ["ModelManagement"]),
        // ACPF profile generation. Pulled into its own target because it links llama via
        // LlamaModelRuntime + ProfileBuilderCore, which the lightweight catalog/downloader does not.
        .library(name: "ModelProfileGeneration", targets: ["ModelProfileGeneration"])
    ],
    dependencies: [
        .package(path: "../AutocompleteCore"),
        .package(path: "../ModelRuntime"),
        .package(path: "../TokenProfiles"),
        .package(path: "../ProfileBuilder")
    ],
    targets: [
        .target(
            name: "ModelManagement",
            dependencies: [
                .product(name: "ModelRuntime", package: "ModelRuntime")
            ]
        ),
        .target(
            name: "ModelProfileGeneration",
            dependencies: [
                "ModelManagement",
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "LlamaModelRuntime", package: "ModelRuntime"),
                .product(name: "TokenProfiles", package: "TokenProfiles"),
                .product(name: "ProfileBuilderCore", package: "ProfileBuilder")
            ]
        ),
        .testTarget(
            name: "ModelManagementTests",
            dependencies: ["ModelManagement"]
        )
    ]
)
