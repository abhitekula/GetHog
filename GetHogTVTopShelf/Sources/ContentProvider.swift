import Foundation
import GetHogKit
import TVServices

/// The completion-handler spelling, not the `async` one. Under Swift 6 strict
/// concurrency the async override is rejected outright — "non-Sendable type
/// '(any TVTopShelfContent)?' cannot be returned from nonisolated override to
/// caller of superclass instance method" — because `TVTopShelfContent` is an
/// ObjC protocol with no Sendable conformance. The completion form crosses no
/// isolation boundary the compiler has to prove safe.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(
        completionHandler: @escaping ((any TVTopShelfContent)?) -> Void
    ) {
        // Synchronous and file-local on purpose: the header asks for the
        // handler "as soon as possible", and everything this process knows is
        // one JSON read away. No fetch, no queue hop, no isolation boundary
        // for the compiler to prove safe across a non-Sendable ObjC protocol.
        let store = SharedSnapshotStore.shared
        let content = TopShelfContent.make(snapshot: store.loadOrNil(), now: Date())
        guard !content.sections.isEmpty,
              let artwork = TopShelfArtworkStore.ensureArtwork(in: store.directory)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(content.sectioned(artwork: artwork))
    }
}
