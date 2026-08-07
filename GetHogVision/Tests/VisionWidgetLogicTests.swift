import Foundation
import GetHogKit
import Testing

/// What the Vision widgets stand on. They never call the API — the appex
/// carries no network entitlement at all — so the App Group container is the
/// whole of their read path, and a container that silently fell back to a
/// private directory is a widget that renders its empty state forever with no
/// error anywhere. That failure is invisible from inside the extension, which
/// is why it is asserted here, from the entitled host app.
@Suite("Vision widget data path")
struct VisionWidgetLogicTests {

    /// Runs inside `GetHog.app`, which carries `group.app.gethog`. Fails if the
    /// entitlement, the App Group, or the resolver's usability probe stops
    /// agreeing on this platform — each of which the app and the widget would
    /// otherwise discover separately, and only as missing data.
    @Test("the App Group container is real on this platform")
    func sharedContainerResolves() {
        #expect(SharedSnapshotStore.shared.isSharedContainer)
    }

    /// The Vision app and its widgets share the iOS-style App Group spelling,
    /// so a missing snapshot should point back to the app. This is deliberately
    /// the opposite of the Mac fallback, where an unshared container cannot
    /// honestly promise that opening the app will make the extension see it.
    @Test("an unshared container still says to open GetHog here")
    func unsharedContainerUsesTheVisionCopy() {
        #expect(
            WidgetCache.noDataMessage(sharedContainer: false)
                == "Open GetHog to sync"
        )
    }
}
