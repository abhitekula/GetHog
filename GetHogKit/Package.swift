// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GetHogKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v15), // so `swift test` runs from the CLI without a simulator
    ],
    products: [
        .library(name: "GetHogKit", targets: ["GetHogKit"]),
    ],
    targets: [
        .target(
            name: "GetHogKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "GetHogKitTests",
            dependencies: ["GetHogKit"],
            resources: [
                // Deterministic synthetic API shapes.
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
