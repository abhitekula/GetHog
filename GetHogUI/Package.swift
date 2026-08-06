// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GetHogUI",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .watchOS(.v26),
        .tvOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "GetHogUI", targets: ["GetHogUI"]),
    ],
    dependencies: [
        .package(path: "../GetHogKit"),
    ],
    targets: [
        .target(
            name: "GetHogUI",
            dependencies: ["GetHogKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Not `GetHogUITests`, which is already an Xcode UI-test bundle in this
        // project and would make `-only-testing:` ambiguous by name — and not
        // `GetHogUIPackageTests` either, which reads better and does not build:
        // SwiftPM names a package's generated test bundle
        // `<package>PackageTests.xctest`, so a target spelled that way is its
        // own product and the build graph closes a cycle on it
        // ("error: build cycle detected", reproduced and reverted).
        .testTarget(
            name: "GetHogUIModuleTests",
            dependencies: ["GetHogUI", "GetHogKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
