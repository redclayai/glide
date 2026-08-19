// swift-tools-version: 6.0

import PackageDescription

// Personalization owns the on-device, opt-in writing-history store (encrypted at rest with
// SQLCipher) plus local-only completion telemetry and a conservative threshold tuner. It conforms
// to `WritingHistoryProviding` from `Prompting` so the app can swap it in for the M3 in-memory stub
// without touching the prompt builder. Kept free of AppKit and of the decoder package: the tuner
// emits a neutral `ThresholdAdjustments` value the app maps onto `DecodingConfiguration`, so this
// package stays decoupled (see the always-on architecture rules).
//
// SQLCipher is provided through the `sqlcipher/GRDB.swift` managed fork, which auto-enables
// SQLCipher encryption without requiring Swift package traits (so it resolves cleanly inside the
// Xcode workspace). See ADR-023.
let package = Package(
    name: "Personalization",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Personalization", targets: ["Personalization"])
    ],
    dependencies: [
        .package(path: "../AutocompleteCore"),
        .package(path: "../Prompting"),
        .package(url: "https://github.com/sqlcipher/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "Personalization",
            dependencies: [
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "Prompting", package: "Prompting"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "PersonalizationTests",
            dependencies: [
                "Personalization",
                .product(name: "Prompting", package: "Prompting"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
