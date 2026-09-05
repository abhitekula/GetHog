// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GetHogKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        // The three platforms the app targets added. An xcodebuild destination
        // already floors a package build at the SDK's own minimum, so the kit
        // compiled for tvOS before these lines existed — they are here so the
        // manifest states the same five platforms GetHogUI's does, and so
        // `swift build --triple` and any future non-Xcode consumer floor where
        // the apps do rather than at the watchOS-4-era default.
        .watchOS(.v26),
        .tvOS(.v26),
        .visionOS(.v26),
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
