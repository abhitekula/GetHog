import Foundation
import Testing

@Suite("GetHog product identity source contracts")
struct GetHogProductIdentitySourceTests {
    private var checkout: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var appRoot: URL {
        checkout.appending(path: "GetHog")
    }

    @Test("the source plist declares GetHog deep links without iOS background work")
    func sourcePlistIdentity() throws {
        let plist = try propertyList(at: appRoot.appending(path: "Support/GetHog-Info.plist"))

        let urlTypes = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
        let urlType = try #require(urlTypes.first)
        #expect(urlTypes.count == 1)
        #expect(urlType["CFBundleURLName"] as? String == "app.gethog.GetHog")
        #expect(urlType["CFBundleURLSchemes"] as? [String] == ["gethog"])
        #expect(plist["BGTaskSchedulerPermittedIdentifiers"] == nil)
        #expect(plist["UIBackgroundModes"] == nil)
        #expect(plist["NSUserActivityTypes"] as? [String] == ["app.gethog.browsing"])
    }

    @Test("the app and widgets share only the GetHog containers")
    func sourceEntitlementIdentity() throws {
        let support = appRoot.appending(path: "Support")
        let app = try propertyList(at: support.appending(path: "GetHog.entitlements"))
        let widgets = try propertyList(at: support.appending(path: "GetHogWidgets.entitlements"))

        for entitlements in [app, widgets] {
            #expect(
                entitlements["com.apple.security.application-groups"] as? [String]
                    == ["group.app.gethog"]
            )
            #expect(
                entitlements["keychain-access-groups"] as? [String]
                    == ["$(AppIdentifierPrefix)app.gethog.shared"]
            )
        }
        #expect(app as NSDictionary == widgets as NSDictionary)
    }

    @Test("server-side alert copy does not advertise the removed local alert system")
    func serverAlertCopyNamesItsBoundary() throws {
        let source = try String(
            contentsOf: appRoot.appending(path: "Sources/Alerts/InsightAlertsView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("PostHog evaluates these on its own servers"))
        #expect(source.contains("does not deliver a separate local alert"))
        #expect(!source.contains("use Metric alerts"))
        #expect(!source.contains("watches the widget snapshot"))
    }

    @Test("launch controls use the GetHog namespace")
    func launchControls() throws {
        let source = try String(
            contentsOf: appRoot.appending(path: "Sources/App/DebugLaunch.swift"),
            encoding: .utf8
        )
        let expectedNames = [
            "GETHOG_OPEN_DASHBOARD",
            "GETHOG_OPEN_TILE",
            "GETHOG_TAB",
            "GETHOG_SOLO_DASHBOARD",
            "GETHOG_OPEN_URL",
        ]
        for name in expectedNames {
            #expect(source.contains("\"\(name)\""), "missing \(name)")
        }
        let legacyPrefix = ["MOBILE", "HOG_"].joined()
        #expect(!source.contains(legacyPrefix))

        let appSource = try String(
            contentsOf: appRoot.appending(path: "Sources/App/GetHogApp.swift"),
            encoding: .utf8
        )
        for name in ["GETHOG_API_KEY", "GETHOG_REGION"] {
            #expect(appSource.contains("\"\(name)\""), "missing \(name)")
        }
        #expect(!appSource.contains(legacyPrefix))
    }

    @Test("the authoritative graph names GetHog products")
    func buildGraphNames() throws {
        let project = try String(
            contentsOf: checkout.appending(path: "project.yml"),
            encoding: .utf8
        )
        for name in ["GetHog", "GetHogWidgets", "GetHogTests", "GetHogUITests", "GetHogScreenshots"] {
            #expect(project.contains("\(name):"), "missing \(name)")
        }
        #expect(project.contains("path: GetHogKit"))
        for bundleID in [
            "app.gethog.GetHog",
            "app.gethog.GetHog.Widgets",
            "app.gethog.GetHogTests",
            "app.gethog.GetHogUITests",
            "app.gethog.GetHogScreenshots",
        ] {
            #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: \(bundleID)"), "missing \(bundleID)")
        }

        let package = try String(
            contentsOf: checkout.appending(path: "GetHogKit/Package.swift"),
            encoding: .utf8
        )
        for declaration in [
            "name: \"GetHogKit\"",
            "name: \"GetHogKitTests\"",
        ] {
            #expect(package.contains(declaration), "missing \(declaration)")
        }

        let legacyApp = ["Mobile", "Hog"].joined()
        let legacyPackage = ["Post", "HogKit"].joined()
        for source in [project, package] {
            #expect(!source.contains(legacyApp))
            #expect(!source.contains(legacyPackage))
        }

        let topLevelNames = try FileManager.default.contentsOfDirectory(atPath: checkout.path)
        let authoritativeNames = topLevelNames.filter { !$0.hasSuffix(".xcodeproj") }
        #expect(
            !authoritativeNames.contains(where: { $0.contains(legacyApp) || $0.contains(legacyPackage) })
        )
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(value as? [String: Any])
    }
}
