import Foundation
import Testing

@testable import GetHog

/// Parsing a PostHog console URL back into a destination.
///
/// This is the half of link handling that can be wrong without anyone noticing:
/// a path that silently resolves to the wrong object, or — worse — the right
/// object id read out of a URL that named a *different project*, which would put
/// one project's numbers on screen under another project's name. The parser is
/// pure so every one of those cases can be pinned here rather than inferred from
/// a screenshot.
@Suite("PostHog links")
struct PostHogLinkTests {

    private func parse(_ string: String) -> PostHogLinkTarget? {
        guard let url = URL(string: string) else { return nil }
        return PostHogLinkParser.parse(url)
    }

    // MARK: - Objects

    @Test("a console dashboard URL resolves to that dashboard in that project")
    func dashboard() {
        let target = parse("https://us.posthog.com/project/1001/dashboard/128")
        #expect(target?.projectID == 1_001)
        #expect(target?.link == .dashboard(id: 128))
        #expect(target?.link.opensInApp == true)
    }

    @Test("a feature flag URL resolves to that flag")
    func featureFlag() {
        let target = parse("https://us.posthog.com/project/1001/feature_flags/700101")
        #expect(target?.projectID == 1_001)
        #expect(target?.link == .featureFlag(id: 700_101))
    }

    @Test("a replay URL keeps the session id verbatim")
    func replay() {
        // Session ids are opaque strings, not numbers: parsing one as an Int
        // would drop every real recording.
        let target = parse("https://us.posthog.com/project/2/replay/0192f3a1-7c2e-70b1-9d4e-abc")
        #expect(target?.link == .sessionRecording(id: "0192f3a1-7c2e-70b1-9d4e-abc"))
    }

    @Test("an error tracking URL resolves to that issue")
    func errorIssue() {
        let target = parse("https://eu.posthog.com/project/77/error_tracking/9c1f-issue")
        #expect(target?.projectID == 77)
        #expect(target?.link == .errorIssue(id: "9c1f-issue"))
    }

    @Test("an insight URL resolves to the insight, and opens in the app")
    func insightOpensInApp() {
        let target = parse("https://us.posthog.com/project/1001/insights/AbC12xYz")
        #expect(target?.projectID == 1_001)
        #expect(target?.link == .insight(shortID: "AbC12xYz"))
        // This asserted `false` for as long as the app drew an insight only as a
        // dashboard tile. `SavedInsightDetailView` is the screen that made it
        // true, and the console fallback below is now the *share* target rather
        // than the destination.
        #expect(target?.link.opensInApp == true)
        #expect(target?.link.webPath == "insights/AbC12xYz")
    }

    /// The console builds its links from an 8-character handle; this app's own
    /// widgets and intents write the numeric id into the same slot — see
    /// `IntentNavigationTarget.linkTarget`. Both have to survive the parser
    /// unchanged, because it is `SavedInsightStore.resolve` that decides which
    /// spelling it has, and it can only do that if the parser did not coerce.
    @Test("an insight id is carried verbatim in either spelling")
    func insightIdentifierIsVerbatim() {
        #expect(
            parse("https://us.posthog.com/project/1/insights/demo0001")?.link
                == .insight(shortID: "demo0001")
        )
        #expect(
            parse("gethog://project/1/insights/710101")?.link
                == .insight(shortID: "710101")
        )
    }

    @Test("every link kind now opens in the app")
    func nothingFallsBackToTheConsole() {
        // The whole point of the change this suite records: `opensInApp` had one
        // `false` arm and it was insight's. If a later case adds another, it
        // should be a deliberate decision that fails here first.
        let links: [PostHogLink] = [
            .screen(.insights),
            .dashboard(id: 1),
            .featureFlag(id: 1),
            .sessionRecording(id: "a"),
            .errorIssue(id: "a"),
            .insight(shortID: "a"),
        ]
        for link in links {
            #expect(link.opensInApp, "\(link) does not open in the app")
        }
    }

    // MARK: - Sections

    @Test("a section URL with no object resolves to the matching screen")
    func sections() {
        #expect(parse("https://us.posthog.com/project/1/dashboard")?.link == .screen(.dashboards))
        #expect(parse("https://us.posthog.com/project/1/feature_flags")?.link == .screen(.flags))
        #expect(parse("https://us.posthog.com/project/1/replay")?.link == .screen(.sessions))
        #expect(parse("https://us.posthog.com/project/1/error_tracking")?.link == .screen(.errorTracking))
        // Was refused outright until there was a list to send anyone to.
        #expect(parse("https://us.posthog.com/project/1/insights")?.link == .screen(.insights))
    }

    @Test("replay's own list pages are the Sessions screen, not a recording id")
    func replayListPages() {
        // `/replay/recent` is the console's list, not a recording. Treating the
        // last segment as an id would send the user to a detail screen that
        // could only ever report "not found".
        #expect(parse("https://us.posthog.com/project/1/replay/recent")?.link == .screen(.sessions))
        #expect(parse("https://us.posthog.com/project/1/replay/home")?.link == .screen(.sessions))
        #expect(parse("https://us.posthog.com/project/1/replay/playlists")?.link == .screen(.sessions))
    }

    @Test("query strings and trailing slashes don't change the destination")
    func decoration() {
        let target = parse("https://us.posthog.com/project/1001/dashboard/128/?date_from=-7d")
        #expect(target?.projectID == 1_001)
        #expect(target?.link == .dashboard(id: 128))
    }

    @Test("a self-hosted host resolves like a cloud one")
    func selfHosted() {
        // The region is user-configured and can be any host, so matching on
        // posthog.com would break exactly the deployments that need this most.
        let target = parse("https://posthog.example/project/8/dashboard/3")
        #expect(target?.projectID == 8)
        #expect(target?.link == .dashboard(id: 3))
    }

    // MARK: - Custom scheme

    @Test("the custom scheme mirrors the console's own path grammar")
    func customScheme() {
        let target = parse("gethog://project/1001/dashboard/128")
        #expect(target?.projectID == 1_001)
        #expect(target?.link == .dashboard(id: 128))
    }

    @Test("the metric widget's authoritative route selects its project before its dashboard")
    func metricWidgetRoute() {
        let target = parse("gethog://project/1001/dashboard/725101")
        #expect(target?.projectID == 1_001)
        #expect(target?.link == .dashboard(id: 725_101))
    }

    @Test("a custom-scheme link may name no project, meaning the selected one")
    func customSchemeWithoutProject() {
        let target = parse("gethog://error_tracking")
        #expect(target?.projectID == nil)
        #expect(target?.link == .screen(.errorTracking))
    }

    @Test("every screen round-trips through a generated URL")
    func everyScreenRoundTrips() {
        // `url(for:)` has to be total: a quick action item carries the string it
        // returns, so a screen it could not name would put a long-press on a URL
        // the parser then refuses.
        for tab in AppTab.allCases {
            let target = PostHogLinkTarget(projectID: nil, link: .screen(tab))
            #expect(PostHogLinkParser.parse(PostHogLinkParser.url(for: target)) == target)
        }
    }

    @Test("every object kind round-trips through a generated URL")
    func roundTrip() {
        let targets: [PostHogLinkTarget] = [
            PostHogLinkTarget(projectID: nil, link: .screen(.search)),
            PostHogLinkTarget(projectID: nil, link: .screen(.errorTracking)),
            PostHogLinkTarget(projectID: 42, link: .dashboard(id: 7)),
            PostHogLinkTarget(projectID: 42, link: .featureFlag(id: 7)),
            PostHogLinkTarget(projectID: 42, link: .sessionRecording(id: "abc-def")),
            PostHogLinkTarget(projectID: 42, link: .errorIssue(id: "abc-def")),
            PostHogLinkTarget(projectID: 42, link: .insight(shortID: "demo0001")),
            // The numeric spelling a widget or an intent writes. It has to come
            // back as an insight rather than as anything else, which is the one
            // thing `sections` gaining an `insights` row could have broken.
            PostHogLinkTarget(projectID: 42, link: .insight(shortID: "710101")),
        ]
        for target in targets {
            #expect(PostHogLinkParser.parse(PostHogLinkParser.url(for: target)) == target)
        }
    }

    // MARK: - Refusals

    @Test("a path with no screen behind it is refused rather than guessed at")
    func unknownPath() {
        #expect(parse("https://us.posthog.com/project/1/settings/organization-billing") == nil)
        #expect(parse("https://us.posthog.com/") == nil)
        #expect(parse("gethog://knitting") == nil)
    }

    @Test("a malformed or non-web URL is refused")
    func malformed() {
        #expect(parse("not a url at all") == nil)
        #expect(parse("mailto:someone@example.com") == nil)
        #expect(parse("file:///etc/passwd") == nil)
        // A numeric object id is required where the console uses one; a
        // half-typed URL must not resolve to some other dashboard.
        #expect(parse("https://us.posthog.com/project/1/dashboard/new") == nil)
        #expect(parse("https://us.posthog.com/project/abc/dashboard/1") == nil)
    }
}

@Suite("GetHog product identity")
struct GetHogProductIdentityTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("custom URLs use the GetHog scheme")
    func customURLScheme() throws {
        let target = PostHogLinkTarget(projectID: nil, link: .screen(.dashboards))
        #expect(PostHogLinkParser.url(for: target).scheme == "gethog")
    }

    @Test("the source plist declares GetHog deep links and background work")
    func sourcePlistIdentity() throws {
        let plist = try propertyList(at: repositoryRoot.appending(path: "Support/GetHog-Info.plist"))

        let urlTypes = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
        let urlType = try #require(urlTypes.first)
        #expect(urlTypes.count == 1)
        #expect(urlType["CFBundleURLName"] as? String == "app.gethog.GetHog")
        #expect(urlType["CFBundleURLSchemes"] as? [String] == ["gethog"])
        #expect(
            plist["BGTaskSchedulerPermittedIdentifiers"] as? [String]
                == ["app.gethog.refresh.snapshot"]
        )
        #expect(plist["NSUserActivityTypes"] as? [String] == ["app.gethog.browsing"])
    }

    @Test("the app and widgets share only the GetHog containers")
    func sourceEntitlementIdentity() throws {
        let support = repositoryRoot.appending(path: "Support")
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

    @Test("launch controls use the GetHog namespace")
    func launchControls() throws {
        #expect(DemoTransport.launchArgument == "-GetHogDemo")

        let source = try String(
            contentsOf: repositoryRoot.appending(path: "Sources/App/DebugLaunch.swift"),
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
            contentsOf: repositoryRoot.appending(path: "Sources/App/GetHogApp.swift"),
            encoding: .utf8
        )
        for name in ["GETHOG_API_KEY", "GETHOG_REGION"] {
            #expect(appSource.contains("\"\(name)\""), "missing \(name)")
        }
        #expect(!appSource.contains(legacyPrefix))
    }

    @Test("the authoritative graph names GetHog products")
    func buildGraphNames() throws {
        let checkout = repositoryRoot.deletingLastPathComponent()
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
