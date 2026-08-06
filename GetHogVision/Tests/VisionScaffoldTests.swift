import Foundation
import Testing

/// The seed suite: proves the target hosts tests at all, and pins the one
/// fact this wave establishes — the universal-purchase bundle identity the
/// visionOS app shares with iOS and macOS.
@Suite("Vision scaffold")
struct VisionScaffoldTests {
    @Test("the host app carries the shared bundle identity")
    func hostBundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "app.gethog.GetHog")
    }
}
