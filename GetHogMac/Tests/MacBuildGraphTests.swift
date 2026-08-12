import Foundation
import FoundationXML
import Testing

@Suite("Mac build graph")
struct MacBuildGraphTests {

    /// All application targets deliberately share the GetHog product name.
    /// Letting an explicit scheme infer dependencies can therefore match a
    /// different platform's GetHog.app and produce two outputs at one path.
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
                "\(name) must not infer another platform's same-named GetHog.app product"
            )
        }
    }
}
