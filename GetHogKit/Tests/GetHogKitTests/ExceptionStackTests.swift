import Foundation
import Testing

@testable import GetHogKit

@Suite("Exception stack traces")
struct ExceptionStackTests {

    private func occurrence(_ fixture: String) throws -> ExceptionOccurrence {
        let response = try QueryResponse.decode(from: Fixture.data(fixture))
        return try #require(ExceptionOccurrence.first(in: response))
    }

    // MARK: - The resolved case

    @Test("reads a resolved frame's original-source name and position")
    func resolvedFrame() throws {
        let occurrence = try occurrence("exception_resolved_frame.json")

        #expect(occurrence.level == "error-synthetic-added")
        #expect(occurrence.fingerprint?.isEmpty == false)
        #expect(occurrence.chain.exceptions.count == 1)

        let thrown = try #require(occurrence.chain.thrown)
        #expect(thrown.type == "LedgerFetchFault")
        #expect(thrown.value == "Ledger response could not be decoded.")
        #expect(thrown.mechanism?.handled == true)
        #expect(thrown.mechanism?.type == "generic")
        #expect(thrown.stack?.kind == .resolved)

        let frame = try #require(thrown.frames.first)
        #expect(frame.isResolved)
        #expect(!frame.isMinified)
        // The demangled name wins over the fixture's single-letter mangled name.
        #expect(frame.functionName == "fetchHarborLedger")
        #expect(frame.mangledName == "h")
        #expect(frame.fileName == "ledger-gateway.ts")
        #expect(frame.isInApp)
    }

    /// The rule the whole model exists to enforce.
    ///
    /// The fixture frame is 47:18 in the original TypeScript and 1:3607 in
    /// the shipped bundle. Printing either number beside the other file would put
    /// a reader at a position that does not exist.
    @Test("never pairs the bundle's position with the source file's name")
    func coordinateSpacesDoNotMix() throws {
        let frame = try #require(
            try occurrence("exception_resolved_frame.json").chain.thrown?.frames.first
        )

        let location = try #require(frame.location)
        #expect(location.line == 47)
        #expect(location.column == 18)

        let raw = try #require(frame.raw)
        #expect(raw.line == 1)
        #expect(raw.column == 3_607)
        #expect(raw.chunkID?.isEmpty == false)

        // Resolved, so the source file and the source position travel together.
        #expect(frame.locationDescription == "ledger-gateway.ts:47:18")
    }

    // MARK: - The unresolved case

    /// The reason `StackTrace.kind` is advisory and `StackFrame.isResolved` is
    /// not: this fixture's stacktrace says `"resolved"` while four of its five
    /// frames failed to resolve.
    @Test("treats per-frame resolution as the fact, not the stack's own label")
    func stackLabelDoesNotImplyResolvedFrames() throws {
        let occurrence = try occurrence("exception_unresolved_frames.json")
        let thrown = try #require(occurrence.chain.thrown)
        let stack = try #require(thrown.stack)

        #expect(stack.kind == .resolved)
        #expect(stack.frames.count == 5)
        #expect(stack.resolvedCount == 1)
        #expect(stack.frames.count(where: \.isMinified) == 4)
    }

    @Test("reports an unresolved frame against the bundle it actually came from")
    func unresolvedFrameUsesRawCoordinates() throws {
        let frames = try occurrence("exception_unresolved_frames.json").chain.thrown?.frames ?? []
        let frame = try #require(frames.first { !$0.isResolved })

        #expect(frame.isMinified)
        #expect(frame.resolvedName == nil)
        // Keep the reason so a missing map and an unavailable map remain distinct.
        #expect(frame.resolveFailure == "Synthetic source map was unavailable at the reserved demo host")

        let location = try #require(frame.location)
        let raw = try #require(frame.raw)
        #expect(location.line == raw.line)
        #expect(location.column == raw.column)
        #expect(frame.fileName?.hasSuffix(".js") == true)
    }

    /// `?` is what a JS SDK emits for an anonymous function. Printed raw it reads
    /// as a rendering bug in the app rather than as a fact about the code.
    @Test("spells out an anonymous frame instead of printing a bare question mark")
    func anonymousFrameIsNamed() throws {
        let frames = try occurrence("exception_unresolved_frames.json").chain.thrown?.frames ?? []
        let anonymous = try #require(frames.first { $0.mangledName == "?" })
        #expect(anonymous.functionName == "(anonymous)")
    }

    @Test("finds the in-app frames the collapsed view shows first")
    func inAppFiltering() throws {
        let stack = try #require(
            try occurrence("exception_unresolved_frames.json").chain.thrown?.stack
        )
        #expect(stack.inAppFrames.count == 4)
        #expect(stack.inAppFrames.count < stack.frames.count)
    }

    // MARK: - Chains

    @Test("renders a cause chain as a chain, thrown exception first")
    func chainedExceptions() throws {
        let chain = try occurrence("exception_chained_synthetic.json").chain

        #expect(chain.isChained)
        #expect(chain.exceptions.count == 3)

        // The list arrives root-cause-first; the app reads it the other way.
        #expect(chain.exceptions.first?.type == "ArchiveNodeFault")
        #expect(chain.thrown?.type == "WorkspaceOpenFault")
        #expect(chain.causes.map(\.type) == ["IndexLookupFault", "ArchiveNodeFault"])
        #expect(chain.orderedForDisplay.map(\.type) == [
            "WorkspaceOpenFault", "IndexLookupFault", "ArchiveNodeFault",
        ])

        // `mechanism.source` is what names the link — `raise … from err` sets
        // `__cause__`, and that word is what the chain row prints.
        #expect(chain.thrown?.mechanism?.type == "chained")
        #expect(chain.thrown?.mechanism?.source == "__cause__")
        #expect(chain.thrown?.mechanism?.handled == false)
        // The root cause is not itself chained to anything.
        #expect(chain.exceptions.first?.mechanism?.type == "generic")
    }

    @Test("a single exception is not a chain")
    func singleExceptionIsNotAChain() throws {
        let chain = try occurrence("exception_resolved_frame.json").chain
        #expect(!chain.isChained)
        #expect(chain.causes.isEmpty)
        #expect(chain.orderedForDisplay.count == 1)
    }

    // MARK: - Absent and malformed input

    /// Both fixtures deliberately carry a null `$exception_steps`, and the screen
    /// must show nothing rather than an empty card.
    @Test("reads no breadcrumb steps when the SDK sent none")
    func noStepsInFixtures() throws {
        #expect(try occurrence("exception_resolved_frame.json").steps.isEmpty)
        #expect(try occurrence("exception_unresolved_frames.json").steps.isEmpty)
    }

    @Test("decodes breadcrumb steps from the documented shape when present")
    func stepsDecodeFromDocumentedShape() throws {
        let json = """
            [{"$message":"clicked checkout","$timestamp":"2026-01-13T04:08:30.100000Z","cart_items":3},
             {"$message":"POST /orders"}]
            """
        let steps = ExceptionStep.decodeList(from: .string(json))

        #expect(steps.count == 2)
        #expect(steps[0].message == "clicked checkout")
        #expect(steps[0].timestamp != nil)
        // The two PostHog defines are lifted out; whatever the caller attached
        // stays, because dropping it would discard the part they chose to record.
        #expect(steps[0].customProperties.map(\.key) == ["cart_items"])
        #expect(steps[1].timestamp == nil)
        #expect(steps[1].customProperties.isEmpty)
    }

    @Test("an event with no exception list yields no occurrence at all")
    func missingExceptionListIsNotAnEmptyTrace() throws {
        let body = Data(
            """
            {"columns":["uuid","timestamp","exception_list","level"],
             "results":[["u1","2026-01-13T00:00:00Z",null,"error"]]}
            """.utf8
        )
        let response = try QueryResponse.decode(from: body)
        #expect(ExceptionOccurrence.first(in: response) == nil)
    }

    @Test("a frame missing every optional field still renders something honest")
    func sparseFrame() throws {
        let entries = try #require(
            ExceptionChain.decode(from: Data(#"[{"type":"Error","value":"boom"}]"#.utf8))
        )
        let thrown = try #require(entries.thrown)
        #expect(thrown.type == "Error")
        #expect(thrown.frames.isEmpty)
        #expect(thrown.stack == nil)

        let bare = StackFrame(isResolved: false)
        #expect(bare.functionName == "(anonymous)")
        #expect(bare.fileDescription == nil)
        #expect(bare.locationDescription == nil)
        #expect(bare.isMinified)
    }
}
