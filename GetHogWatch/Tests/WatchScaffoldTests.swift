import Foundation
import Testing

/// The seed suite: proves the target hosts tests at all, and pins the one
/// fact this wave establishes — the watch app's own bundle id under the iOS
/// app's.
@Suite("Watch scaffold")
struct WatchScaffoldTests {
    @Test("the host app carries the watch app's own bundle identity")
    func hostBundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "app.gethog.GetHog.watchkitapp")
    }
}
