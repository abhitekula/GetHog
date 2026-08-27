import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Trace Quick Preview")
struct TraceQuickPreviewTests {
    @Test("a short trace identifier remains intact and the root names the operation")
    func shortIdentifierAndRootOperationArePresented() throws {
        let presentation = TraceQuickPreviewPresentation(trace: try Self.trace(
            id: "tr-42",
            rootName: "POST /synthetic/checkout"
        ))

        #expect(presentation.identifier == "tr-42")
        #expect(presentation.operation == "POST /synthetic/checkout")
    }

    @Test("the service is only presented when the trace has a root span")
    func serviceIsOptional() throws {
        let loaded = TraceQuickPreviewPresentation(trace: try Self.trace(
            id: "trace-with-service",
            rootService: "synthetic-checkout"
        ))
        let empty = TraceQuickPreviewPresentation(trace: TraceGroup(id: "empty-trace", spans: []))

        #expect(loaded.service == "synthetic-checkout")
        #expect(empty.service == nil)
    }

    @Test("sub-millisecond and long trace durations retain their readable units")
    func durationKeepsReadableScale() throws {
        let subMillisecond = TraceQuickPreviewPresentation(trace: try Self.trace(
            id: "trace-sub-ms",
            rootDurationNanos: 400_000
        ))
        let long = TraceQuickPreviewPresentation(trace: try Self.trace(
            id: "trace-long",
            rootDurationNanos: 4_500_000_000
        ))

        #expect(subMillisecond.duration == "400 µs")
        #expect(long.duration == "4.5 s")
    }

    @Test("the aggregate error status and counts include all already-loaded spans")
    func aggregateStatusAndCountsUseLoadedSpans() throws {
        let successful = TraceQuickPreviewPresentation(trace: try Self.trace(id: "trace-ok"))
        let failed = TraceQuickPreviewPresentation(trace: try Self.trace(
            id: "trace-error",
            childStatus: "error"
        ))

        #expect(successful.status == "OK")
        #expect(successful.spanCount == 1)
        #expect(successful.errorCount == 0)
        #expect(failed.status == "Error")
        #expect(failed.spanCount == 2)
        #expect(failed.errorCount == 1)
    }

    private static func trace(
        id: String,
        rootName: String = "GET /synthetic/checkout",
        rootService: String = "synthetic-api",
        rootDurationNanos: Int = 2_000_000,
        childStatus: String? = nil
    ) throws -> TraceGroup {
        var spans = [try span(
            traceID: id,
            spanID: "root",
            parentSpanID: nil,
            name: rootName,
            service: rootService,
            status: "ok",
            durationNanos: rootDurationNanos,
            isRoot: true
        )]
        if let childStatus {
            spans.append(try span(
                traceID: id,
                spanID: "child",
                parentSpanID: "root",
                name: "POST synthetic dependency",
                service: rootService,
                status: childStatus,
                durationNanos: 500_000,
                isRoot: false
            ))
        }
        return TraceGroup(id: id, spans: spans)
    }

    private static func span(
        traceID: String,
        spanID: String,
        parentSpanID: String?,
        name: String,
        service: String,
        status: String,
        durationNanos: Int,
        isRoot: Bool
    ) throws -> TraceSpan {
        try #require(TraceSpan(row: QueryRow(
            columns: [
                "uuid", "trace_id", "span_id", "parent_span_id", "name",
                "service_name", "status_code", "timestamp", "duration_nano", "is_root_span",
            ],
            values: [
                .string("\(traceID)-\(spanID)"), .string(traceID), .string(spanID),
                parentSpanID.map(JSONValue.string) ?? .null, .string(name), .string(service),
                .string(status), .string("2026-08-27T14:15:30Z"), .number(Double(durationNanos)),
                .bool(isRoot),
            ]
        )))
    }
}
