import SwiftUI

/// Identifier for the "looking at a PostHog page" activity.
///
/// Must also appear in `NSUserActivityTypes` in the app's Info.plist, or the
/// system drops the activity and Handoff silently never appears.
enum HandoffActivity {
    static let browsing = "app.gethog.browsing"

    /// Key under which the continued URL is carried, for receivers that read
    /// `userInfo` instead of `webpageURL`.
    static let urlKey = "webpageURL"
}

/// Continues the current screen on another device by handing off the equivalent
/// PostHog web page.
///
/// `webpageURL` is what makes this work without a Mac app: any device that can
/// open a browser can pick the activity up, which is the whole point — the deep
/// analysis a phone can't do happens in the web console.
struct HandoffModifier: ViewModifier {
    let webURL: URL?
    let title: String

    func body(content: Content) -> some View {
        // No URL means no continuation: `isActive: false` withdraws the activity
        // rather than publishing an empty one, so a screen without a web
        // equivalent doesn't offer a Handoff banner that goes nowhere.
        content.userActivity(HandoffActivity.browsing, isActive: webURL != nil) { activity in
            guard let webURL else { return }
            activity.title = title
            activity.webpageURL = webURL
            activity.isEligibleForHandoff = true
            // Deliberately not searchable or publicly indexed: these URLs name a
            // private analytics project and belong to one account.
            activity.isEligibleForSearch = false
            activity.isEligibleForPublicIndexing = false
            activity.userInfo = [HandoffActivity.urlKey: webURL.absoluteString]
        }
    }
}

extension View {
    /// Offers this screen for Handoff to its PostHog web equivalent.
    ///
    /// A no-op when `webURL` is nil, so callers can pass
    /// `model.webURL(path:)` straight through without unwrapping.
    func handoff(webURL: URL?, title: String) -> some View {
        modifier(HandoffModifier(webURL: webURL, title: title))
    }
}
