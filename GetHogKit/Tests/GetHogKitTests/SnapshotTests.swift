import Foundation
import Testing

@testable import GetHogKit

@Suite("Session replay snapshots")
struct SnapshotTests {

    @Test("decodes the blob_v2 source listing")
    func decodesSources() throws {
        let listing = try SnapshotSourceListing.decode(from: Fixture.data("snapshot_sources.json"))

        #expect(listing.sources.count == 1)
        #expect(listing.sources[0].source == "blob_v2")
        #expect(listing.sources[0].blobKey == "0")
        #expect(listing.sources[0].startTimestamp != nil)
    }

    @Test("chunks blob keys into ranges of at most 20 per request")
    func chunksBlobRanges() throws {
        let listing = try SnapshotSourceListing.decode(from: Fixture.data("snapshot_sources.json"))

        // PostHog rejects more than 20 blobs in a single request, and rejects a
        // lone `blob_key` for blob_v2 ("Must provide both start blob key and end
        // blob key"), so requests are always ranges.
        let ranges = listing.blobRanges(maxPerRequest: 20)

        #expect(ranges.count == 1)
        #expect(ranges[0].start == "0")
        #expect(ranges[0].end == "0")
    }

    @Test("parses JSONL snapshot lines into window-tagged rrweb events in order")
    func parsesJSONL() throws {
        let events = try SnapshotParser.parse(jsonl: Fixture.data("snapshot_blobs.jsonl"))

        #expect(events.count == 7)
        #expect(events.first?.timestamp == 1_768_478_400_000)
        #expect(events[0].windowID == "018f1000-0000-7000-8000-000000000002")
        #expect(events[0].type == 4)

        // A player needs at least one FullSnapshot (type 2) to build the initial
        // DOM, plus incremental mutations (type 3) to animate it.
        #expect(events.contains { $0.type == 2 })
        #expect(events.contains { $0.type == 3 })

        // Timestamps must stay monotonically ordered for playback to make sense.
        let timestamps = events.map(\.timestamp)
        #expect(timestamps == timestamps.sorted())
    }

    @Test("decodes the handcrafted full snapshot into usable rrweb data")
    func decodesFullSnapshots() throws {
        let events = try SnapshotParser.parse(jsonl: Fixture.data("snapshot_blobs.jsonl"))
        let full = try #require(events.first { $0.isFullSnapshot })

        guard case .object(let data) = full.event["data"] else {
            Issue.record("full snapshot data was not decoded into an object")
            return
        }
        #expect(data["node"] != nil)
    }

    @Test("leaves already-decoded incremental payloads untouched")
    func leavesPlainPayloadsAlone() throws {
        let events = try SnapshotParser.parse(jsonl: Fixture.data("snapshot_blobs.jsonl"))
        let incremental = try #require(events.first { $0.type == 3 })

        guard case .object(let data) = incremental.event["data"] else {
            Issue.record("incremental data should already be an object")
            return
        }
        #expect(data["source"] != nil)
    }

    @Test("gunzips a stream carrying a filename header field")
    func gunzipHandlesOptionalHeaderFields() throws {
        // FNAME-bearing streams are legal gzip; a fixed 10-byte header
        // assumption would silently corrupt them.
        let payload = Data(#"{"hello":"world"}"#.utf8)
        let gzipped = try #require(TestGzip.compress(payload, fileName: "snapshot.json"))
        let out = try #require(Gunzip.decompress(gzipped))
        #expect(out == payload)
    }

    @Test("skips malformed lines instead of failing the whole batch")
    func toleratesMalformedLines() throws {
        let junk = Data("not json\n[\"win\",{\"timestamp\":1,\"type\":3,\"data\":{}}]\n\n".utf8)
        let events = try SnapshotParser.parse(jsonl: junk)
        #expect(events.count == 1)
        #expect(events[0].windowID == "win")
    }
}
