// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ConstrainedGeneration",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ConstrainedGeneration", targets: ["ConstrainedGeneration"])
    ],
    dependencies: [
        .package(path: "../AppCompatibility"),
        .package(path: "../AutocompleteCore"),
        .package(path: "../ModelRuntime"),
        .package(path: "../Prompting"),
        .package(path: "../TokenProfiles")
    ],
    targets: [
        .target(
            name: "ConstrainedGeneration",
            dependencies: [
                .product(name: "AppCompatibility", package: "AppCompatibility"),
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "TokenProfiles", package: "TokenProfiles")
            ]
        ),
        // Deterministic tests run everywhere via `TreeScriptedModelRuntime` +
        // `InMemoryAutocompleteProfile`. The on-device acceptance test depends on
        // `LlamaModelRuntime` and is `XCTSkipUnless`-gated on the GGUF + ACPF profile being
        // present locally (the llama xcframework must be vendored to build this target — same
        // requirement as `ModelRuntimeTests`).
        .testTarget(
            name: "ConstrainedGenerationTests",
            dependencies: [
                "ConstrainedGeneration",
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "LlamaModelRuntime", package: "ModelRuntime"),
                .product(name: "Prompting", package: "Prompting"),
                .product(name: "TokenProfiles", package: "TokenProfiles")
            ]
        )
    ]
)
