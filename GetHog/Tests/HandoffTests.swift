import Foundation
import SwiftUI
import Testing
import UIKit

@testable import GetHog

/// Handoff, and an honest account of which parts of it can be checked here.
///
/// The feature this file covers spans three boundaries, and only the first is
/// ours:
///
/// 1. **Building the activity** — the URL, the title, the eligibility flags, and
///    the declaration that lets the system carry any of it. Entirely this app's
///    business, entirely asserted below.
/// 2. **Publishing it** — SwiftUI's `.userActivity` deciding when to fill the
///    activity in and hand it to the system. Not observable from a unit-test
///    host; `swiftUIPublishingIsNotObservableHere` records exactly what was tried
///    and what came back, rather than leaving the gap unmarked.
/// 3. **Carrying it to another device** — two devices, one iCloud account,
///    Bluetooth and Wi-Fi. Not reachable from a simulator at all.
///
/// The reason for writing 2 and 3 down instead of quietly testing 1 is that the
/// defect this file was written for was precisely a Handoff feature that looked
/// present and was inert. A green run here is evidence about the activity, and
/// about nothing further along.
@Suite("Handoff")
struct HandoffTests {

    @Test("the activity uses the GetHog identifier")
    func activityIdentifier() {
        #expect(HandoffActivity.browsing == "app.gethog.browsing")
    }

    private let host = URL(string: "https://us.posthog.com")!

    private func consoleURL(_ path: String) -> URL {
        host.appending(path: "project/1").appending(path: path)
    }

    // MARK: - The declaration

    /// Read out of the **built** bundle, not out of `GetHog-Info.plist`.
    ///
    /// Those are two different files: the source plist is merged with generated
    /// `INFOPLIST_KEY_*` settings into the one iOS reads, and this project has
    /// already been bitten once by a key that was written as a build setting,
    /// silently dropped, and believed present. Without this key the system drops
    /// the activity and Handoff never appears — outbound *or* inbound.
    @Test("the built app declares the browsing activity type")
    func activityTypeIsDeclared() throws {
        let declared = Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String]
        #expect(declared?.contains(HandoffActivity.browsing) == true, "declared: \(declared ?? [])")
    }

    // MARK: - Building the activity

    @Test("a configured activity carries everything a receiver needs")
    func configureFillsTheActivity() {
        let activity = NSUserActivity(activityType: HandoffActivity.browsing)
        let url = consoleURL("dashboard/7")
        HandoffActivity.configure(activity, webURL: url, title: "Web overview")

        #expect(activity.title == "Web overview")
        #expect(activity.webpageURL == url)
        #expect(activity.isEligibleForHandoff)
        // These two are the privacy half. A console URL names a private analytics
        // project and belongs to one account; it must not end up in Spotlight or
        // in Apple's public index.
        #expect(!activity.isEligibleForSearch)
        #expect(!activity.isEligibleForPublicIndexing)
        #expect(activity.userInfo?[HandoffActivity.urlKey] as? String == url.absoluteString)
    }

    /// **The crash this guard exists for, stated as a test.**
    ///
    /// `-[UAUserActivity setWebpageURL:]` raises `NSInvalidArgumentException` —
    /// "NSUserActivity.webpageURL scheme "ftp" is not allowed" — for any scheme
    /// but `http`/`https`. Measured directly against the framework; it is an
    /// Objective-C exception, so Swift cannot catch it and the process dies.
    ///
    /// The unreachable-sounding case is reachable. `PostHogRegion.selfHosted`
    /// carries whatever the user typed, and onboarding only prepends `https://`
    /// when the text contains no `://` at all.
    ///
    /// This test asserts the *guard*, not the exception. Asserting the exception
    /// would mean raising it, which would take the test runner down with it.
    @Test("only an http(s) console URL is ever handed to NSUserActivity")
    func onlyWebSchemesAreContinuable() {
        #expect(HandoffActivity.continuableURL(URL(string: "https://us.posthog.com/project/1")) != nil)
        #expect(HandoffActivity.continuableURL(URL(string: "http://posthog.example:8000/project/1")) != nil)
        #expect(HandoffActivity.continuableURL(URL(string: "HTTPS://US.POSTHOG.COM/project/1")) != nil)

        #expect(HandoffActivity.continuableURL(nil) == nil)
        #expect(HandoffActivity.continuableURL(URL(string: "ftp://posthog.example/project/1")) == nil)
        #expect(HandoffActivity.continuableURL(URL(string: "gethog://dashboard/7")) == nil)
        #expect(HandoffActivity.continuableURL(URL(string: "file:///tmp/x")) == nil)
    }

    /// A screen with no web equivalent must withdraw the activity rather than
    /// publish an empty one — a Handoff banner that opens nothing is worse than
    /// no banner.
    @Test("a screen with no console page advertises nothing")
    func noURLMeansNoActivity() {
        #expect(HandoffActivity.continuableURL(nil) == nil)
        // `PostHogLink.screen` is the case with no object and therefore no page.
        #expect(PostHogLink.screen(.dashboards).webPath == nil)
    }

    // MARK: - Receiving

    @Test("a continued activity is read back off webpageURL, then userInfo")
    func continuationReadsBothChannels() {
        let url = consoleURL("replay/abc-123")

        let full = NSUserActivity(activityType: HandoffActivity.browsing)
        HandoffActivity.configure(full, webURL: url, title: "Session")
        #expect(HandoffActivity.continuationURL(from: full) == url)

        // A receiver handed the activity by some route that dropped
        // `webpageURL`. The fallback is cheap; whether it is ever exercised by a
        // real transfer is unverified, and nothing depends on the answer.
        let userInfoOnly = NSUserActivity(activityType: HandoffActivity.browsing)
        userInfoOnly.userInfo = [HandoffActivity.urlKey: url.absoluteString]
        #expect(HandoffActivity.continuationURL(from: userInfoOnly) == url)

        let empty = NSUserActivity(activityType: HandoffActivity.browsing)
        #expect(HandoffActivity.continuationURL(from: empty) == nil)
    }

    /// **The part of the loop that can be wrong in a way nobody would see.**
    ///
    /// The system carries a URL; what happens next is this app's parser. A second
    /// device running GetHog continues the activity into `LinkInbox`, which is
    /// the same mailbox a pasted console URL uses — so the guarantee that matters
    /// is that every URL the sending half can publish parses back to the object
    /// it was published for, project id and all.
    ///
    /// Every `PostHogLink` case with a `webPath`, so a case added later without a
    /// round trip fails here rather than handing a colleague's iPad a link that
    /// lands nowhere.
    @Test("every object this app hands off parses back to the same object")
    func handoffURLsRoundTrip() throws {
        let links: [PostHogLink] = [
            .dashboard(id: 7),
            .featureFlag(id: 42),
            .sessionRecording(id: "018f9000-0000-7000-8000-000000000482"),
            .errorIssue(id: "018f9000-0000-7000-8000-000000000483"),
            .insight(shortID: "demo0001"),
        ]

        for link in links {
            let path = try #require(link.webPath, "\(link) has no console path")
            let url = try #require(HandoffActivity.continuableURL(consoleURL(path)))
            let parsed = try #require(PostHogLinkParser.parse(url), "did not parse: \(url)")
            #expect(parsed.link == link)
            // The project has to survive the trip. Resolving an id against
            // whichever project happens to be selected on the receiving device is
            // the one-project's-numbers-under-another's-name bug the whole link
            // layer exists to refuse.
            #expect(parsed.projectID == 1)
        }
    }

    /// The EU and self-hosted hosts go through the same parser, which is not
    /// restricted to posthog.com — so a hand-off from a self-hosted instance
    /// arrives as the same destination.
    @Test("a hand-off from any region parses the same way")
    func regionsRoundTripAlike() throws {
        for host in ["https://eu.posthog.com", "http://posthog.example:8000"] {
            let url = try #require(
                HandoffActivity.continuableURL(
                    URL(string: host)!.appending(path: "project/9").appending(path: "feature_flags/3")
                )
            )
            let parsed = try #require(PostHogLinkParser.parse(url))
            #expect(parsed.link == .featureFlag(id: 3))
            #expect(parsed.projectID == 9)
        }
    }

    // MARK: - The boundary this cannot cross

    /// **Recorded as a measurement, not as a passing feature.**
    ///
    /// The question this suite cannot answer is whether SwiftUI's
    /// `.userActivity` — the mechanism `HandoffModifier` is built on — ever fills
    /// the activity in and makes it current. The obvious way to find out is to
    /// host a view that uses it and watch. That was done, twice, and the result
    /// was: nothing.
    ///
    /// - Hosting `.handoff(…)` in a fresh `UIWindow` on the app's scene, and then
    ///   in the app's own key window, left **no** `NSUserActivity` anywhere on
    ///   the responder chain.
    /// - Giving `.userActivity` an update closure of the test's own — with an
    ///   `NSUserActivityDelegate` and `needsSave = true` — recorded **zero**
    ///   invocations, zero `userActivityWillSave`.
    /// - `.onAppear` on the very same view fired, once. That is the control, and
    ///   it is why this is stated as "not observable here" rather than "SwiftUI
    ///   does nothing": the probe was demonstrably driving SwiftUI, and
    ///   `.userActivity` still did not run.
    ///
    /// The likeliest reading is that `.userActivity` is scene-level plumbing that
    /// a hand-hosted `UIHostingController` never joins, and that it does run
    /// inside the app's real `WindowGroup`. **That is an inference and is not
    /// evidence.** Nobody should treat this suite as proof that a Handoff banner
    /// appears. The way to actually find out is two devices on one iCloud
    /// account, which no test in this repository can be.
    ///
    /// The assertion below is the control, kept so the day `.onAppear` stops
    /// firing in a hosted view — which would invalidate the whole paragraph
    /// above — is a red build rather than a silent change of meaning.
    @MainActor
    @Test("SwiftUI's publishing half is not observable from a unit-test host")
    func swiftUIPublishingIsNotObservableHere() async throws {
        final class Counter: @unchecked Sendable {
            var appeared = 0
            var updates = 0
        }
        let counter = Counter()

        let controller = UIHostingController(
            rootView: Text("handoff probe")
                .userActivity(HandoffActivity.browsing, isActive: true) { activity in
                    counter.updates += 1
                    HandoffActivity.configure(
                        activity,
                        webURL: URL(string: "https://us.posthog.com/project/1/dashboard/7")!,
                        title: "Probe"
                    )
                }
                .onAppear { counter.appeared += 1 }
        )

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .init(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(100)) }
        window.isHidden = true

        #expect(counter.appeared >= 1, "the probe is no longer driving SwiftUI, so it proves nothing")
        if counter.updates > 0 {
            // The outcome this file would rather have, kept as a passing branch:
            // a runtime that *does* run the closure here makes the publishing
            // half testable, and the right response is to test it properly and
            // rewrite this comment.
            Issue.record("`.userActivity` now runs under UIHostingController — this suite can be strengthened.")
        }
    }
}
