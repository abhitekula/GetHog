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
    ]
)
