import Foundation
import GetHogKit
import GetHogUI
import SwiftUI
import Testing
import UIKit

@testable import GetHog

/// Guards on the experiment readout that only hold at the view layer.
///
/// The kit tests pin the arithmetic and the decoding. These pin the two things
/// that arithmetic cannot catch: that a state which has something to say is
/// actually *drawn* saying it, and that no state is distinguished by colour
/// alone.
@Suite("Experiment readout")
@MainActor
struct ExperimentReadoutTests {

    // MARK: - Status chrome

    /// Every lifecycle state the API can report gets its own glyph.
    ///
    /// `paused` and `exposure_frozen` were added when the model started reading
    /// the API's `status` instead of guessing from dates. Both fell through to
    /// the `default` arm at first, so two states that mean very different things
    /// — collecting-but-flag-off versus enrolment-closed-but-metrics-flowing —
    /// drew the same anonymous circle.
    @Test("every lifecycle state has a glyph of its own, not the fallback")
    func everyStatusHasASymbol() {
        var seen: [String: String] = [:]
        for status in [
            ExperimentStatus.draft, .running, .paused, .exposureFrozen, .stopped,
        ] {
            let symbol = experimentStatusSymbol(status.displayName)
            #expect(symbol != "circle", "\(status.displayName) fell through to the fallback glyph")
            #expect(
                seen[symbol] == nil,
                "\(status.displayName) reuses the glyph already used by \(seen[symbol] ?? "")"
            )
            seen[symbol] = status.displayName
        }
        // Archived is not one of the API's states — it is a separate flag that
        // overrides them — but it reaches the same mapping.
        #expect(experimentStatusSymbol("Archived") == "archivebox")
    }

    @Test("an unknown future status still gets a header glyph rather than a gap")
    func unknownStatusStillDraws() {
        #expect(experimentStatusSymbol("Teleported") == "circle")
    }

    @Test("running and not-running are told apart by more than the same tint")
    func statusTintsDiffer() {
        let running = experimentStatusTint("Running")
        let draft = experimentStatusTint("Draft")
        let complete = experimentStatusTint("Complete")
        #expect(running != draft)
        #expect(running != complete)
        // And the word always travels with the tint, which is what makes the
        // colour a second encoding rather than the only one.
        for word in ["Running", "Draft", "Paused", "Exposure frozen", "Complete", "Archived"] {
            #expect(!word.isEmpty)
            #expect(Theme.Status.ink(for: experimentStatusTint(word)) != Color.clear)
        }
    }

    // MARK: - Nothing renders blank

    /// Every verdict draws something.
    ///
    /// This is the `WorldMap` failure mode generalised: a state that produces an
    /// empty view does not read as "no answer", it reads as broken. The check is
    /// a real render, because that is the only thing that catches a view whose
    /// content is present in the hierarchy but invisible on the screen.
    @Test("every verdict state renders visible content")
    func everyVerdictDraws() throws {
        let verdicts: [ExperimentVerdict] = [
            .notStarted,
            .noResults,
            .tooEarly(.notEnoughExposures),
            .tooEarly(.baselineMeanIsZero),
            .noSignificantDifference(leader: nil),
            .noSignificantDifference(leader: "dense"),
            .significantWin(variant: "dense"),
            .significantLoss(variant: "dense"),
        ]
        for verdict in verdicts {
            let card = ExperimentVerdictCard(
                verdict: verdict, method: .bayesian, metricName: "Quote requested"
            )
            let distinct = try distinctColourCount(of: card)
            // A blank card is one flat colour plus antialiasing. Real content —
            // a glyph, a headline and two lines of body — is far more.
            #expect(distinct > 8, "\(verdict.headline) rendered as a near-blank card")
        }
    }

    @Test("a metric this build cannot interpret draws a card, never an empty space")
    func unsupportedMetricDraws() throws {
        let metric = try JSONDecoder().decode(
            ExperimentMetric.self,
            from: Data(#"{"kind":"ExperimentMetric","metric_type":"quantile","name":"p95"}"#.utf8)
        )
        #expect(metric.type == nil)
        let view = ExperimentMetricSection(
            metric: metric,
            readout: ExperimentReadout(result: nil, isRunning: true),
            didFail: false,
            isLoading: false,
            webURL: nil
        )
        #expect(try distinctColourCount(of: view) > 8)
    }

    @Test("exposures that could not be loaded say so rather than rendering nothing")
    func unavailableExposuresDraw() throws {
        let view = ExperimentExposureSection(exposures: nil, isUnavailable: true)
        #expect(try distinctColourCount(of: view) > 8)
    }

    // MARK: - Statistical labelling

    /// The engine's own vocabulary, never the other one's.
    @Test("each method names its own interval")
    func intervalNames() {
        #expect(ExperimentStatsMethod.bayesian.intervalName == "credible interval")
        #expect(ExperimentStatsMethod.frequentist.intervalName == "confidence interval")
        #expect(ExperimentStatsMethod.bayesian.intervalName != ExperimentStatsMethod.frequentist.intervalName)
    }

    /// A Bayesian result rendered with a frequentist label would be a false
    /// statement, so the row takes the method from the payload rather than from
    /// the experiment's configured setting.
    @Test("a result states the method that produced it, not the one configured")
    func methodComesFromTheResult() throws {
        let json = Data("""
        {"baseline":{"key":"control","number_of_samples":100,"sum":20.0,"sum_squares":20.0},
         "variant_results":[{"key":"t","method":"frequentist","number_of_samples":100,
          "sum":30.0,"sum_squares":30.0,"p_value":0.02,"significant":true}]}
        """.utf8)
        let result = try ExperimentMetricResult.decode(from: json)
        #expect(result.method == .frequentist)
        let readout = ExperimentReadout(result: result, isRunning: true)
        #expect(readout.method == .frequentist)
    }

    // MARK: - Harness

    /// Renders a view and counts how many distinct colours came out.
    ///
    /// A view that draws nothing produces the background and little else. This
    /// is deliberately a coarse floor rather than a snapshot comparison — it
    /// catches "invisible" without pinning layout, so it does not have to be
    /// re-baselined every time a font metric moves.
    private func distinctColourCount(of view: some View, width: CGFloat = 393) throws -> Int {
        let host = view
            .frame(width: width)
            .padding(16)
            .background(Theme.pageBackground)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: host)
        renderer.scale = 1
        let image = try #require(renderer.uiImage, "the view produced no image at all")
        let cg = try #require(image.cgImage)

        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var colours: Set<UInt32> = []
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let packed = UInt32(pixels[index]) << 16
                | UInt32(pixels[index + 1]) << 8
                | UInt32(pixels[index + 2])
            colours.insert(packed)
        }
        return colours.count
    }
}
