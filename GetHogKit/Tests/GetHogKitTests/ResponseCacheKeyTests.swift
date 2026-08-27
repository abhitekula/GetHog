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
        #expect(
            ResponseCache.filename(for: key)
                == "v2-49528b9b8a1935265bde752b86b49f1b9461a40725f3be78772bdc2f9b0f08e2"
        )
    }

    @Test("different keys do not collide")
    func distinct() {
        let a = ResponseCache.filename(for: "/content/?width=375")
        let b = ResponseCache.filename(for: "/content/?width=425")
        #expect(a != b)
    }

    @Test("a real scoped cache file has only a versioned opaque digest")
    func scopedIdentityIsOpaqueAtRest() async throws {
        let subdirectory = "GetHogOpaqueCacheNameTests-\(UUID().uuidString)"
        let directory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(subdirectory, isDirectory: true)
        let cache = ResponseCache(subdirectory: subdirectory)
        let key = """
        018F9000-0000-7000-8000-000000000710
        GET
        https://preview.example.invalid/api/projects/1001/insights/725001/?refresh=force_cache&marker=readable-fragment
        """

        #expect(await cache.store(Data("synthetic".utf8), for: key))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let name = try #require(names.first)

        #expect(names.count == 1)
        #expect(name.range(of: #"^v2-[0-9a-f]{64}$"#, options: .regularExpression) != nil)
        for forbidden in [
            "preview", "example", "invalid", "1001", "725001", "refresh",
            "force_cache", "readable", "018F9000", "/", "?", "&", "=",
        ] {
            #expect(!name.localizedCaseInsensitiveContains(forbidden))
        }

        #expect(await cache.clear())
    }

    @Test("an empty key is still a valid filename")
    func empty() {
        #expect(
            ResponseCache.filename(for: "")
                == "v2-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test("initialization removes legacy readable-suffix files without touching opaque entries")
    func legacyReadableFilesAreCleaned() {
        let directory = URL(fileURLWithPath: "/synthetic/cache", isDirectory: true)
        let storage = ResponseCacheTestStorage()
        let legacy = "f83757b5ff686fa8-_api_projects_1001_insights_725001_refresh_force_cache"
        let opaque = ResponseCache.filename(for: "synthetic-current-key")
        storage.seed(Data("legacy".utf8), named: legacy, in: directory)
        storage.seed(Data("current".utf8), named: opaque, in: directory)

        _ = ResponseCache(directory: directory, storage: storage)

        #expect(storage.names() == [opaque])
    }

    @Test("a failed legacy cleanup is retried on the next cache initialization")
    func legacyCleanupFailureRetriesOnInitialization() {
        let directory = URL(fileURLWithPath: "/synthetic/legacy-retry", isDirectory: true)
        let storage = ResponseCacheTestStorage()
        let legacy = "f83757b5ff686fa8-_api_projects_1001_insights_725001_refresh_force_cache"
        storage.seed(Data("legacy".utf8), named: legacy, in: directory)
        storage.blockRemoval(named: legacy)

        _ = ResponseCache(directory: directory, storage: storage)
        #expect(storage.names().contains(legacy))

        storage.unblockRemoval(named: legacy)
        _ = ResponseCache(directory: directory, storage: storage)
        #expect(!storage.names().contains(legacy))
    }

    @Test("failed removal hides the entry and retries the durable cleanup obligation")
    func removeFailureHidesEntryUntilCleanupSucceeds() async {
        let directory = URL(fileURLWithPath: "/synthetic/remove-retry", isDirectory: true)
        let storage = ResponseCacheTestStorage()
        let cache = ResponseCache(directory: directory, storage: storage)
        let key = "synthetic-remove-key"
        let filename = ResponseCache.filename(for: key)
        #expect(await cache.store(Data("sensitive response".utf8), for: key))
        storage.blockRemoval(named: filename)

        #expect(await cache.remove(key) == false)
        #expect(await cache.entry(for: key) == nil)
        #expect(storage.names().contains(filename))

        storage.unblockRemoval(named: filename)
        #expect(await cache.entry(for: key) == nil)
        #expect(!storage.names().contains(filename))
    }

    @Test("failed generation clear revokes reads immediately and resumes after restart")
    func failedGenerationClearIsDurableAcrossInitialization() async {
        let directory = URL(fileURLWithPath: "/synthetic/clear-retry", isDirectory: true)
        let storage = ResponseCacheTestStorage()
        let cache = ResponseCache(directory: directory, storage: storage)
        let key = "synthetic-sign-out-key"
        let filename = ResponseCache.filename(for: key)
        #expect(await cache.store(Data("sensitive response".utf8), for: key))
        let lease = await cache.issuePublicationLease(namespace: "synthetic-auth-epoch")
        storage.blockRemoval(named: filename)

        #expect(await cache.revokeAllPublicationsAndClear() == false)
        guard case .revoked = await cache.entry(for: key, lease: lease) else {
            Issue.record("The old generation could still read after clear failed.")
            return
        }
        #expect(storage.names().contains(filename))

        storage.unblockRemoval(named: filename)
        let restarted = ResponseCache(directory: directory, storage: storage)
        let replacementLease = await restarted.issuePublicationLease(
            namespace: "synthetic-auth-epoch"
        )
        guard case .available(let replacementEntry) = await restarted.entry(
            for: key,
            lease: replacementLease
        ) else {
            Issue.record("The replacement cache generation was unexpectedly revoked.")
            return
        }
        #expect(replacementEntry == nil)
        #expect(!storage.names().contains(filename))
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
