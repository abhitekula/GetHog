import Foundation
import Testing

@testable import GetHogKit

@Suite("Snapshot refresh lease", .serialized)
struct SnapshotRefreshLeaseTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> (SnapshotRefreshLeaseStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotRefreshLeaseTests-synthetic", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (SnapshotRefreshLeaseStore(directory: directory), directory)
    }

    private func scope(
        projectID: Int = 1001,
        authSessionID: UUID = UUID(uuidString: "018f9000-0000-7000-8000-000000000600")!
    ) -> SnapshotRefreshScope {
        SnapshotRefreshScope(
            projectID: projectID,
            projectName: "Example App",
            region: .usCloud,
            authSessionID: authSessionID
        )
    }

    @Test("a second process cannot acquire an active lease")
    func activeLeaseIsExclusive() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try #require(store.acquire(scope: scope(), trigger: .manualWidget, now: t0))

        #expect(store.acquire(scope: scope(), trigger: .automaticWidget, now: t0) == nil)
        #expect(store.current(now: t0)?.token == first.token)
    }

    @Test("only the lease owner can release it")
    func releaseRequiresOwnerToken() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try #require(store.acquire(scope: scope(), trigger: .manualWidget, now: t0))

        store.release(token: UUID(uuidString: "018f9000-0000-7000-8000-000000000601")!)
        #expect(store.current(now: t0) != nil)

        store.release(token: lease.token)
        #expect(store.current(now: t0) == nil)
    }

    @Test("a thirty-second-old abandoned lease can be replaced")
    func abandonedLeaseExpires() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(store.acquire(scope: scope(), trigger: .manualWidget, now: t0))

        let replacement = try #require(store.acquire(
            scope: scope(),
            trigger: .manualWidget,
            now: t0.addingTimeInterval(30)
        ))

        #expect(replacement.token != first.token)
        #expect(store.current(now: t0.addingTimeInterval(30))?.token == replacement.token)
    }

    @Test("an active lease for another project blocks a conflicting snapshot write")
    func anotherScopeIsStillExclusive() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try #require(store.acquire(scope: scope(projectID: 1001), trigger: .foreground, now: t0))

        #expect(store.acquire(
            scope: scope(projectID: 1002),
            trigger: .manualWidget,
            now: t0
        ) == nil)
    }
}
