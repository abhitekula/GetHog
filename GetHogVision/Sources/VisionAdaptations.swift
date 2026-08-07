#if os(visionOS)
import Foundation
import GetHogKit

// The Vision twins of the two symbols shared code names out of the four files
// this target excludes. Deliberately *only* those two — unlike the Mac's
// `MacAdaptations`, which also shims ~15 iOS-only APIs, because every one of
// those is real API on visionOS: `navigationBarTitleDisplayMode`,
// `.topBarLeading`, `listRowSpacing`, `.insetGrouped`, `EditButton`,
// `keyboardType`, `textInputAutocapitalization`, `navigationBarDrawer`,
// `fullScreenCover`, `UIPasteboard`, the real `\.horizontalSizeClass`. The Mac
// target is the proof this list is complete: it compiles the same shared
// catalog minus the same four files.

/// No-op twin of the iOS home screen quick actions (the real one is
/// `App/QuickActions.swift`, excluded from this target). visionOS has no
/// app-icon shortcut menu to feed, so the seven shared call sites record into
/// nothing rather than being seamed one by one.
@MainActor
enum QuickActions {
    static func recordPinnedDashboard(id: Int, title: String, projectID: Int) {}
    static func recordVisit(_ link: PostHogLink, title: String, projectID: Int) {}
    static func refresh(projectID: Int?) {}
    static func clear() {}
}

/// Vision twin of the iOS BGTaskScheduler wrapper (excluded from this target).
///
/// Unlike the Mac's, this forwards to a scheduler of the same species —
/// `VisionRefresh` is `BGTaskScheduler` too. What makes the twin necessary is
/// not the mechanism but the wiring: the excluded file registers its handler
/// from `GetHogApp`, which is also excluded. `AppModel.signOut` calls
/// `cancel()` on every platform and needs to know none of this.
@MainActor
enum BackgroundRefresh {
    static func cancel() { VisionRefresh.cancel() }
}
#endif
