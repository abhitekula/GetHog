import Foundation
import Testing

@Suite("Mac build graph")
struct MacBuildGraphTests {

    /// The storefront identity is shared, but Vision and TV use unique build
    /// products. Letting an explicit scheme infer dependencies can still widen
    /// a graph, so schemes remain closed over declared dependencies too.
    /// Parse the generated artifact—not project.yml text—so this also catches
    /// a generator schema change that silently drops the isolation setting.
    @Test("generated schemes build only their declared platform graph")
    func generatedSchemesDisableImplicitDependencies() throws {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemeDirectory = checkout
            .appending(path: "GetHog.xcodeproj/xcshareddata/xcschemes")
        let schemeNames = [
            "GetHog",
            "GetHogMac",
            "GetHogVision",
            "GetHogWatch",
            "GetHogTV",
            "GetHogScreenshots",
        ]

        for name in schemeNames {
            let document = try XMLDocument(
                contentsOf: schemeDirectory.appending(path: "\(name).xcscheme"),
                options: []
            )
            let buildAction = try #require(
                document.nodes(forXPath: "/Scheme/BuildAction").first as? XMLElement,
                "missing BuildAction in \(name).xcscheme"
            )
            #expect(
                buildAction.attribute(forName: "buildImplicitDependencies")?.stringValue == "NO",
                "\(name) must remain closed over its declared platform graph"
            )
        }
    }

    /// `TEST_HOST` is resolved from build outputs, not just PBX target edges.
    /// A Vision or TV configuration that also produces `GetHog.app` can be
    /// selected as the Mac unit-test host when a command-line architecture is
    /// supplied, even when the scheme disables implicit dependencies.
    @Test("non-Mac device SDKs cannot produce the Mac test host")
    func nonMacProductsCannotCollideWithMacTestHost() throws {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: checkout.appending(path: "GetHog.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let configurations = try buildConfigurations(in: project)

        for sdk in ["appletvos", "xros"] {
            let colliding = configurations.filter {
                $0.contains("SDKROOT = \(sdk);") && $0.contains("PRODUCT_NAME = GetHog;")
            }
            #expect(
                colliding.isEmpty,
                "\(sdk) still produces GetHog.app and can be selected as the Mac TEST_HOST"
            )
        }

        for host in [
            "GetHogTV.app/GetHogTV",
            "GetHogVision.app/GetHogVision",
        ] {
            #expect(
                project.contains("TEST_HOST = \"$(BUILT_PRODUCTS_DIR)/\(host)\";"),
                "generated hosted-test path does not follow unique product \(host)"
            )
        }

        for product in ["GetHogMac.app", "GetHogTV.app", "GetHogVision.app"] {
            #expect(
                project.contains("path = \(product);"),
                "generated product reference lost unique path \(product)"
            )
        }

        #expect(
            project.contains("TEST_HOST = \"$(BUILT_PRODUCTS_DIR)/GetHogMac.app/Contents/MacOS/GetHogMac\";")
        )

        let macConfigurations = configurations.filter {
            $0.contains("PRODUCT_BUNDLE_IDENTIFIER = app.gethog.GetHog;")
                && $0.contains("PRODUCT_NAME = GetHogMac;")
        }
        #expect(macConfigurations.count == 2)
        for configuration in macConfigurations {
            #expect(configuration.contains("PRODUCT_NAME = GetHogMac;"))
            #expect(configuration.contains("PRODUCT_MODULE_NAME = GetHog;"))
            #expect(configuration.contains("INFOPLIST_KEY_CFBundleDisplayName = GetHog;"))
        }
    }

    @Test("source and processed Mac plists keep the native GetHog short name")
    func macNativeShortName() throws {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceData = try Data(
            contentsOf: checkout.appending(path: "GetHogMac/Support/GetHogMac-Info.plist")
        )
        let source = try #require(
            PropertyListSerialization.propertyList(from: sourceData, format: nil)
                as? [String: Any]
        )

        #expect(source["CFBundleName"] as? String == "GetHog")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "GetHog")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "GetHog")
    }

    /// Xcode 26.6 can collapse test-bundle module outputs to the generic
    /// `.swiftmodule/Project` path when a test target inherits its product and
    /// module names. Each platform scheme builds multiple test bundles, so make
    /// every identity explicit and prove the generated Debug and Release
    /// settings cannot write the same module artifacts.
    @Test("all test bundles have distinct explicit product modules")
    func testBundleModulesAreDistinct() throws {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: checkout.appending(path: "GetHog.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let configurations = try buildConfigurations(in: project)

        let targets = [
            "GetHogTests",
            "GetHogUITests",
            "GetHogScreenshots",
            "GetHogMacTests",
            "GetHogMacUITests",
            "GetHogVisionTests",
            "GetHogVisionUITests",
            "GetHogWatchTests",
            "GetHogWatchUITests",
            "GetHogTVTests",
            "GetHogTVUITests",
        ]
        for target in targets {
            let bundleID = "PRODUCT_BUNDLE_IDENTIFIER = app.gethog.\(target);"
            let targetConfigurations = configurations.filter { $0.contains(bundleID) }
            #expect(targetConfigurations.count == 2, "expected Debug and Release for \(target)")
            for configuration in targetConfigurations {
                #expect(configuration.contains("PRODUCT_NAME = \(target);"))
                #expect(configuration.contains("PRODUCT_MODULE_NAME = \(target);"))
            }
        }
    }

    /// Xcode 26.6 does not carry this generated project's project-level Debug
    /// defaults into application target configurations. Unit tests use
    /// `@testable import`, so every hosted app's Debug target must explicitly
    /// emit a testable, unoptimized module with the DEBUG condition.
    @Test("hosted app Debug configurations are explicitly testable")
    func hostedAppDebugConfigurationsAreTestable() throws {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: checkout.appending(path: "GetHog.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let configurations = try buildConfigurations(in: project)
        let bundleIDs = [
            "app.gethog.GetHog;",
            "app.gethog.GetHog.watchkitapp;",
        ]

        let hostConfigurations = configurations.filter { configuration in
            bundleIDs.contains(where: configuration.contains)
                && !configuration.contains("PRODUCT_BUNDLE_IDENTIFIER = app.gethog.GetHog.Widgets;")
                && !configuration.contains("PRODUCT_BUNDLE_IDENTIFIER = app.gethog.GetHog.TopShelf;")
        }
        let hosts: [(name: String, marker: String)] = [
            ("iOS", "PRODUCT_NAME = GetHog;"),
            ("Mac", "PRODUCT_NAME = GetHogMac;"),
            ("Vision", "INFOPLIST_FILE = \"GetHogVision/Support/GetHogVision-Info.plist\";"),
            ("Watch", "PRODUCT_BUNDLE_IDENTIFIER = app.gethog.GetHog.watchkitapp;"),
            ("TV", "INFOPLIST_FILE = \"GetHogTV/Support/GetHogTV-Info.plist\";"),
        ]
        for host in hosts {
            let debugMatches = hostConfigurations.filter {
                $0.contains(host.marker) && $0.contains("name = Debug;")
            }
            #expect(debugMatches.count == 1, "expected one hosted Debug configuration for \(host.name)")
            let debug = try #require(
                debugMatches.first,
                "missing hosted Debug configuration for \(host.name)"
            )
            #expect(debug.contains("ENABLE_TESTABILITY = YES;"))
            #expect(debug.contains("SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";"))
            #expect(debug.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;"))

            let releaseMatches = hostConfigurations.filter {
                $0.contains(host.marker) && $0.contains("name = Release;")
            }
            #expect(releaseMatches.count == 1, "expected one hosted Release configuration for \(host.name)")
            let release = try #require(
                releaseMatches.first,
                "missing hosted Release configuration for \(host.name)"
            )
            #expect(!release.contains("ENABLE_TESTABILITY = YES;"))
            #expect(!release.contains("SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";"))
            #expect(!release.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;"))
        }
        #expect(hostConfigurations.filter { $0.contains("name = Debug;") }.count == 5)
        #expect(hostConfigurations.filter { $0.contains("name = Release;") }.count == 5)
    }

    @Test("build configuration parser ignores braces in values and comments")
    func parserKeepsQuotedAndCommentBracesInsideOneObject() throws {
        let fixture = #"""
		A /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				QUOTED = "} and {";
				COMMENTED = value; /* } */
			};
			name = Debug;
		};
		B /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				QUOTED = "{";
			};
			name = Release;
		};
"""#

        let parsed = try buildConfigurations(in: fixture)
        #expect(parsed.count == 2)
        #expect(parsed[0].contains("QUOTED = \"} and {\";"))
        #expect(parsed[1].contains("QUOTED = \"{\";"))
    }

    /// Returns complete XCBuildConfiguration objects. Splitting on the `isa`
    /// line loses the object header and leaves the next object's header on the
    /// previous chunk, so predicates can accidentally classify adjacent
    /// configurations. Xcode's exact two-tab object terminator keeps each
    /// generated object isolated without interpreting braces inside values or
    /// comments as OpenStep structure.
    private func buildConfigurations(in project: String) throws -> [String] {
        let lines = project.split(separator: "\n", omittingEmptySubsequences: false)
        var configurations: [String] = []
        var current: [Substring] = []

        for index in lines.indices {
            let line = lines[index]
            if current.isEmpty {
                guard (line.contains("/* Debug */ = {") || line.contains("/* Release */ = {")),
                      lines.indices.contains(index + 1),
                      lines[index + 1].contains("isa = XCBuildConfiguration;") else {
                    continue
                }
            }

            current.append(line)
            if line == "\t\t};" {
                configurations.append(current.joined(separator: "\n"))
                current.removeAll(keepingCapacity: true)
            }
        }

        guard current.isEmpty else { throw BuildConfigurationParsingError.unterminatedObject }
        return configurations
    }

    private enum BuildConfigurationParsingError: Error {
        case unterminatedObject
    }
}
