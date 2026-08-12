import Foundation
import FoundationXML
import Testing

@Suite("Mac build graph")
struct MacBuildGraphTests {

    /// The storefront identity is shared, but each non-Mac SDK uses a unique
    /// build product. Letting an explicit scheme infer dependencies can still
    /// widen a graph, so schemes remain closed over declared dependencies too.
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
        let configurations = project.components(separatedBy: "isa = XCBuildConfiguration;")

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
    }
}
