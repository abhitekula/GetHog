import AppKit
import GetHogKit
import SwiftUI
import Testing
import Vision

@testable import GetHog

@MainActor
@Suite("Error Tracking empty-state composition")
struct ErrorTrackingCompositionTests {

    @Test("regular no-row state presents one complete outcome without a split")
    func regularEmptyCompositionIsSingular() async throws {
        let openDetails = OpenDetails()
        openDetails[.errorTracking] = ErrorIssue(
            id: "stale-issue",
            name: "Stale issue from the previous result"
        )
        let surface = try await renderedSurface(
            contentWidth: 1_100,
            sizeClass: .regular,
            transport: DemoTransport(emptyCollection: .errorTracking),
            openDetails: openDetails,
            settlesWhen: { text in
                contains("No errors in this period", in: text)
                    && contains("Nothing was reported", in: text)
                    && openDetails[.errorTracking] == nil
            }
        )

        #expect(
            occurrences(of: "No errors in this period", in: surface.text) == 1,
            "Regular width repeated its complete empty outcome. OCR: \(surface.text)"
        )
        #expect(contains("Nothing was reported", in: surface.text))
        #expect(!contains("No issues to list", in: surface.text))
        #expect(surface.splitViewCount == 0)
        #expect(openDetails[.errorTracking] == nil)
    }

    @Test("compact screen keeps the one complete empty outcome")
    func compactEmptyCompositionStaysComplete() async throws {
        let openDetails = OpenDetails()
        openDetails[.errorTracking] = ErrorIssue(
            id: "stale-issue",
            name: "Stale issue from the previous result"
        )
        let surface = try await renderedSurface(
            contentWidth: 640,
            sizeClass: .compact,
            transport: DemoTransport(emptyCollection: .errorTracking),
            openDetails: openDetails,
            settlesWhen: {
                contains("No errors in this period", in: $0)
                    && openDetails[.errorTracking] == nil
            }
        )

        #expect(occurrences(of: "No errors in this period", in: surface.text) == 1)
        #expect(contains("Nothing was reported", in: surface.text))
        #expect(!contains("No issues to list", in: surface.text))
        #expect(surface.splitViewCount == 0)
        #expect(openDetails[.errorTracking] == nil)
    }

    @Test("regular populated collection keeps its list-detail split")
    func regularPopulatedCompositionKeepsSplit() async throws {
        let surface = try await renderedSurface(
            contentWidth: 1_100,
            sizeClass: .regular,
            transport: DemoTransport(),
            openDetails: OpenDetails(),
            settlesWhen: {
                contains("HarborRenderFault", in: $0)
                    && contains("By status", in: $0)
            }
        )

        #expect(contains("HarborRenderFault", in: surface.text))
        #expect(contains("By status", in: surface.text))
        #expect(surface.splitViewCount > 0)
    }

    private struct RenderedSurface {
        let text: [String]
        let splitViewCount: Int
    }

    private func renderedSurface(
        contentWidth: CGFloat,
        sizeClass: SwiftUI.UserInterfaceSizeClass,
        transport: any HTTPTransport,
        openDetails: OpenDetails,
        settlesWhen: ([String]) -> Bool
    ) async throws -> RenderedSurface {
        let model = AppModel(
            store: InMemoryTokenStore(
                credential: StoredCredential(key: "demo", region: .usCloud)
            ),
            transport: transport
        )
        await model.bootstrap()
        #expect(model.phase == .ready)

        // Mount the real Mac topology boundary. It supplies a stack to the
        // shared compact list and leaves the regular NavigationSplitView as
        // the screen's own container.
        let root = MacAdaptiveNavigationHost(
            tab: .errorTracking,
            compact: sizeClass == .compact
        ) {
            ErrorTrackingRoot()
        }
        .environment(model)
        .environment(openDetails)
        .environment(\.horizontalSizeClass, sizeClass)

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(CGSize(width: contentWidth, height: 700))
        window.alphaValue = 0.01
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var text: [String] = []
        while ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            text = try recognizedText(in: controller.view)
            if settlesWhen(text) {
                return RenderedSurface(
                    text: text,
                    splitViewCount: splitViewCount(in: controller.view)
                )
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return RenderedSurface(
            text: text,
            splitViewCount: splitViewCount(in: controller.view)
        )
    }

    private func contains(_ phrase: String, in text: [String]) -> Bool {
        text.contains { $0.localizedCaseInsensitiveContains(phrase) }
    }

    private func occurrences(of phrase: String, in text: [String]) -> Int {
        text.reduce(into: 0) { count, candidate in
            var remainder = candidate[...]
            while let range = remainder.range(
                of: phrase,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) {
                count += 1
                remainder = remainder[range.upperBound...]
            }
        }
    }

    private func recognizedText(in view: NSView) throws -> [String] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return []
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }

    private func splitViewCount(in view: NSView) -> Int {
        (view is NSSplitView ? 1 : 0)
            + view.subviews.reduce(0) { $0 + splitViewCount(in: $1) }
    }
}
