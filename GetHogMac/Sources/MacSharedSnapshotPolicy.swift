import Foundation
import GetHogKit

/// Chooses the snapshot boundary that the Mac app is actually entitled to use.
///
/// A teamless Debug build deliberately has no App Group entitlement. Asking
/// Foundation for that container on macOS still resolves the protected Group
/// Containers location before GetHog's writability probe falls back, which is
/// both unnecessary and outside this build's declared authority. Skip that
/// lookup entirely and keep every app-owned cache reader on the private
/// fallback. A signed Release retains the shared store used by its widgets.
enum MacSharedSnapshotPolicy {
    static let store: SharedSnapshotStore = {
        #if GETHOG_UNSHARED_MAC_APP
        SharedSnapshotStore.resolve(container: { _ in nil })
        #else
        SharedSnapshotStore.shared
        #endif
    }()

    static let sharedDefaults: UserDefaults? = {
        #if GETHOG_UNSHARED_MAC_APP
        nil
        #else
        UserDefaults(suiteName: SharedSnapshotStore.bundleAppGroupIdentifier)
        #endif
    }()
}
