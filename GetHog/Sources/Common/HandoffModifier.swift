import SwiftUI

/// Identifier for the "looking at a PostHog page" activity.
///
/// Must also appear in `NSUserActivityTypes` in the app's Info.plist, or the
/// system drops the activity and Handoff silently never appears. It is declared
/// there, and `HandoffDeclarationTests` reads it back out of the *built* bundle
/// rather than out of the source plist — the two are not the same file, and the
/// generated one is what iOS reads.
enum HandoffActivity {
    static let browsing = "app.gethog.browsing"

    /// Key under which the continued URL is carried, for receivers that read
    /// `userInfo` instead of `webpageURL`.
    static let urlKey = "webpageURL"

    /// The URL this activity may legally carry, or nil.
    ///
    /// **Measured, and the reason this function exists at all.** Assigning a
    /// `webpageURL` whose scheme is anything but `http` or `https` does not fail
    /// softly — `-[UAUserActivity setWebpageURL:]` raises
    /// `NSInvalidArgumentException`, "NSUserActivity.webpageURL scheme "ftp" is
    /// not allowed", which is an Objective-C exception Swift cannot catch and
    /// therefore a crash. Verified directly against the `UserActivity` framework:
    /// `https` and `http` are both accepted, `ftp` terminates the process.
    ///
    /// That is reachable from this app rather than theoretical.
    /// `PostHogRegion.selfHosted` carries whatever URL the user typed, and
    /// onboarding only prepends `https://` when the text contains no `://` at
    /// all — so a self-hosted instance entered as `ftp://…`, or a
    /// `GETHOG_REGION` launch argument, produces a console URL with a scheme
    /// `NSUserActivity` refuses. Screens pass `model.webURL(path:)` straight
    /// through, so the check has to live here, once, rather than at five call
    /// sites.
    ///
    /// Returning nil rather than clamping is deliberate: `HandoffModifier` reads
    /// nil as "no continuation", which withdraws the activity instead of
    /// publishing one that goes nowhere.
    static func continuableURL(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        return scheme == "http" || scheme == "https" ? url : nil
    }

    /// Fills in an activity for one screen.
    ///
    /// Separated from the modifier so it can be asserted directly. SwiftUI owns
    /// *when* the update closure runs and whether the result becomes current;
    /// what the activity ends up containing is this function's business alone,
    /// and it is the half a test can pin.
    static func configure(_ activity: NSUserActivity, webURL: URL, title: String) {
        activity.title = title
        activity.webpageURL = webURL
        activity.isEligibleForHandoff = true
        // Deliberately not searchable or publicly indexed: these URLs name a
        // private analytics project and belong to one account.
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = [urlKey: webURL.absoluteString]
    }

    /// The URL a continued activity is asking this app to open.
    ///
    /// `webpageURL` first because that is the channel Handoff is documented to
    /// carry and the one the sending half sets. The `userInfo` fallback is kept
    /// because it costs nothing and covers a receiver that was handed the
    /// activity by some route other than Handoff — but note that it is
    /// **unverified**: whether `userInfo` survives a real device-to-device
    /// transfer without `requiredUserInfoKeys` was not observable from here, and
    /// nothing in this app depends on the answer.
    static func continuationURL(from activity: NSUserActivity) -> URL? {
        if let url = activity.webpageURL { return url }
        guard let string = activity.userInfo?[urlKey] as? String else { return nil }
        return URL(string: string)
    }
}

/// Continues the current screen on another device by handing off the equivalent
/// PostHog web page.
///
/// `webpageURL` is what makes this work without a Mac app: any device that can
/// open a browser can pick the activity up, which is the whole point — the deep
/// analysis a phone can't do happens in the web console. A second device running
/// GetHog picks it up too, and lands on the *app's* screen for the same
/// object rather than in a browser: `GetHogApp` continues the activity into
/// `LinkInbox`, which is the same mailbox a pasted console URL arrives in, and
/// `PostHogLinkParser` already turns that URL back into a destination.
///
/// **What is asserted and what is not.** That the activity is built correctly,
/// and that the type is declared in the built app, are both tested. That a
/// banner appears on a second device is not: Handoff needs two signed-in devices
/// on the same iCloud account with Bluetooth and Wi-Fi, and none of that exists
/// in a simulator or in CI. Nobody should read a green build here as evidence
/// that a hand-off was seen.
struct HandoffModifier: ViewModifier {
    let webURL: URL?
    let title: String

    /// Nil for a screen with no web equivalent, and for one whose console URL
    /// carries a scheme `NSUserActivity` would refuse — see `continuableURL`.
    private var activityURL: URL? { HandoffActivity.continuableURL(webURL) }

    func body(content: Content) -> some View {
        // No URL means no continuation: `isActive: false` withdraws the activity
        // rather than publishing an empty one, so a screen without a web
        // equivalent doesn't offer a Handoff banner that goes nowhere.
        content.userActivity(HandoffActivity.browsing, isActive: activityURL != nil) { activity in
            guard let activityURL else { return }
            HandoffActivity.configure(activity, webURL: activityURL, title: title)
        }
    }
}

extension View {
    /// Offers this screen for Handoff to its PostHog web equivalent.
    ///
    /// A no-op when `webURL` is nil, so callers can pass
    /// `model.webURL(path:)` straight through without unwrapping.
    ///
    /// Applied only to the five **detail** screens — one dashboard, one insight,
    /// one replay, one flag, one issue. Not to lists: "the dashboards list" is
    /// not a thing a person continues on a Mac, and it keeps the number of
    /// screens advertising this activity type at once as small as it can be.
    ///
    /// It does not get it to one. A dashboard tile opens an insight, so both can
    /// be in the same `NavigationStack` and both advertise `browsing`. Which one
    /// the system ends up offering was **not observable from here** — see
    /// `HandoffTests.swiftUIPublishingIsNotObservableHere`, where SwiftUI's
    /// update closure never ran at all in a test host — so this is written down
    /// rather than claimed either way. The plausible reading is last-to-appear
    /// wins, which is the pushed screen and therefore the right one; the case to
    /// actually check on two devices is popping *back*, where the covering
    /// screen's activity has to be withdrawn for the covered one to return.
    func handoff(webURL: URL?, title: String) -> some View {
        modifier(HandoffModifier(webURL: webURL, title: title))
    }
}
