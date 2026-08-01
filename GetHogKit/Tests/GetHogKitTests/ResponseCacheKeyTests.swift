import Foundation
import Testing

@testable import GetHogKit

@Suite("Response cache keys")
struct ResponseCacheKeyTests {

    @Test("the same key always names the same file")
    func stable() {
        let key = "/api/projects/1001/heatmap_screenshots/019e2cd8/content/?width=425"
        // Pinned to a literal on purpose. A test that only compared two calls
        // inside one process would have passed against `String.hashValue` too —
        // the bug was that the number changed between *launches*, which is
        // precisely what a literal catches and a self-comparison cannot.
        #expect(ResponseCache.filename(for: key).hasPrefix("f83757b5ff686fa8-"))
    }

    @Test("different keys do not collide")
    func distinct() {
        let a = ResponseCache.filename(for: "/content/?width=375")
        let b = ResponseCache.filename(for: "/content/?width=425")
        #expect(a != b)
    }

    @Test("query strings survive as a filesystem-safe name")
    func safeName() {
        let name = ResponseCache.filename(for: "/a/b/?x=1&y=2")
        #expect(!name.contains("/"))
        #expect(!name.contains("?"))
        #expect(!name.contains("&"))
        #expect(!name.contains("="))
    }

    @Test("an empty key is still a valid filename")
    func empty() {
        #expect(!ResponseCache.filename(for: "").isEmpty)
    }

    @Test("a rendered page is cached for a day, not for minutes")
    func renderTTL() {
        // The image only changes when a person re-renders the save in the web
        // console, so the short list/event TTLs would re-spend half a megabyte
        // for nothing.
        #expect(ResponseCache.TTL.pageRenders > ResponseCache.TTL.dashboards)
        #expect(ResponseCache.TTL.pageRenders.isFinite)
    }
}
