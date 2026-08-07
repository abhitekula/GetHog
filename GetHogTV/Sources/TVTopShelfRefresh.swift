import SwiftUI
import TVServices

enum TVTopShelfRefresh {

    static func shouldNotify(for phase: ScenePhase) -> Bool { phase == .background }

    static func notifyIfNeeded(for phase: ScenePhase) {
        guard shouldNotify(for: phase) else { return }
        // Synchronous on purpose: a Task hop from a background transition can
        // lose its chance to run before tvOS suspends the app.
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
}
