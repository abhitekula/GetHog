import Foundation
import Testing

/// The seed suite: proves the target hosts tests at all, and pins the one
/// fact this wave establishes — the universal-purchase bundle identity the
/// tvOS app shares with iOS and macOS.
@Suite("TV scaffold")
struct TVScaffoldTests {
    @Test("the host app carries the shared bundle identity")
    func hostBundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "app.gethog.GetHog")
    }
}
