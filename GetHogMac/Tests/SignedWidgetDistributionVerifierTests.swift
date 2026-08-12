import Foundation
import Testing

@Suite("Signed widget built-product verifier")
struct SignedWidgetDistributionVerifierTests {

    @Test("the app is derived from the loaded UI test bundle, never environment input")
    func derivesAppFromRunnerBundle() throws {
        let products = URL(fileURLWithPath: "/tmp/FictionalBuild/Products/Release")
        let testBundle = products.appending(
            path: "GetHogMacUITests-Runner.app/Contents/PlugIns/GetHogMacUITests.xctest"
        )
        let expected = products.appending(path: "GetHogMac.app")
        let extensionURL = expected.appending(path: "Contents/PlugIns/GetHogWidgets.appex")

        let actual = try SignedWidgetDistributionVerifier.applicationURL(
            testBundleURL: testBundle,
            isDirectory: { $0 == expected || $0 == extensionURL }
        )

        #expect(actual == expected)
    }

    @Test("resolved entitlement reports contain statuses and never group values")
    func reportsOnlyKeysAndStatuses() throws {
        let products = URL(fileURLWithPath: "/tmp/FictionalBuild/Products/Release")
        let testBundle = products.appending(path: "GetHogMacUITests.xctest")
        let app = products.appending(path: "GetHogMac.app")
        let widget = app.appending(path: "Contents/PlugIns/GetHogWidgets.appex")
        let group = "fictional-team.group.app.gethog"

        let result = try SignedWidgetDistributionVerifier.verify(
            testBundleURL: testBundle,
            isDirectory: { $0 == app || $0 == widget },
            runCommand: { arguments in
                if arguments.contains("--verify") {
                    return .init(status: 0, output: Data())
                }
                let target = arguments.last
                let entitlements: [String: Any] = target == app.path ? [
                    "com.apple.security.application-groups": [group],
                    "com.apple.security.network.client": true,
                ] : [
                    "com.apple.security.application-groups": [group],
                ]
                return .init(
                    status: 0,
                    output: try PropertyListSerialization.data(
                        fromPropertyList: entitlements,
                        format: .xml,
                        options: 0
                    )
                )
            }
        )

        #expect(result.isAccepted)
        #expect(result.report.contains("parity.com.apple.security.application-groups: matching"))
        #expect(!result.report.contains(group))
    }

    @Test("a mismatched single group fails without disclosing either value")
    func mismatchIsStatusOnly() throws {
        let products = URL(fileURLWithPath: "/tmp/FictionalBuild/Products/Release")
        let testBundle = products.appending(path: "GetHogMacUITests.xctest")
        let app = products.appending(path: "GetHogMac.app")
        let widget = app.appending(path: "Contents/PlugIns/GetHogWidgets.appex")
        let appGroup = "fictional-app-group"
        let widgetGroup = "fictional-widget-group"

        let result = try SignedWidgetDistributionVerifier.verify(
            testBundleURL: testBundle,
            isDirectory: { $0 == app || $0 == widget },
            runCommand: { arguments in
                if arguments.contains("--verify") {
                    return .init(status: 0, output: Data())
                }
                let isApp = arguments.last == app.path
                let entitlements: [String: Any] = [
                    "com.apple.security.application-groups": [isApp ? appGroup : widgetGroup],
                    "com.apple.security.network.client": isApp,
                ]
                return .init(
                    status: 0,
                    output: try PropertyListSerialization.data(
                        fromPropertyList: entitlements,
                        format: .xml,
                        options: 0
                    )
                )
            }
        )

        #expect(!result.isAccepted)
        #expect(result.report.contains("parity.com.apple.security.application-groups: mismatched"))
        #expect(!result.report.contains(appGroup))
        #expect(!result.report.contains(widgetGroup))
    }
}
