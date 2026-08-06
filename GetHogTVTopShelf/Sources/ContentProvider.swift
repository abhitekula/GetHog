import TVServices

/// The Top Shelf stub: declares the extension point so the appex scaffolding
/// (bundle id, embed, entitlements, principal class) can be verified now.
/// Real shelf content arrives with the TV shell in a later task; until then
/// an empty answer keeps the shelf on the system default.
///
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
        completionHandler(nil)
    }
}
