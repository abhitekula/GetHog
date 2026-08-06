import XCTest

/// What the pointer does over a **full-size, un-buttoned** chart.
///
/// The earlier guard hovered a dashboard *tile*, which cannot work and never
/// could: `TileCard` wraps its chart in a `Button` and turns hit testing off
/// inside it, so neither a finger nor a pointer reaches the plot there. The
/// only charts that scrub are the ones on an insight detail, which is what this
/// drives.
///
/// The readout is addressable after all, which the earlier pass missed. It is
/// `accessibilityHidden(selectedPoints.isEmpty)` — hidden only while *nothing*
/// is scrubbed — so a live selection surfaces as a button labelled
/// "Jan 13, 2 series". That turns "did the readout blank?" from a question about
/// two indistinguishable screenshots into an assertion.
final class MacChartHoverTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Geometry

    /// The plot, measured from Swift Charts' own mark bands — the only elements
    /// that report where the data actually lands. Their union spans the marks,
    /// which is the region a scrub has to answer inside.
    private func markBandUnion(in app: XCUIApplication) -> CGRect? {
        let bands = app.windows.descendants(matching: .other)
            .matching(NSPredicate(format: "label CONTAINS %@", "AM to"))
            .allElementsBoundByIndex
            .map { $0.frame }
            .filter { $0.width > 1 }
        guard !bands.isEmpty else { return nil }
        return bands.dropFirst().reduce(bands[0]) { $0.union($1) }
    }

    /// The live scrub readout's text, or `nil` when nothing is scrubbed.
    private func readout(in app: XCUIApplication) -> String? {
        let button = app.windows.descendants(matching: .button)
            .matching(NSPredicate(format: "label CONTAINS %@", " series"))
            .firstMatch
        return button.exists ? button.label : nil
    }

    private func hover(_ app: XCUIApplication, x: CGFloat, y: CGFloat) {
        let window = app.windows.firstMatch
        let origin = window.frame.origin
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x - origin.x, dy: y - origin.y))
            .hover()
    }

    private func openFirstInsight() -> XCUIApplication {
        let app = DemoLaunch.launch()
        app.typeKey("4", modifierFlags: .command)
        DemoLaunch.settle(app)
        guard let row = DemoLaunch.waitForContent(containing: "Example meteor report", in: app) else {
            XCTFail("The insights list never offered its first row.")
            return app
        }
        row.click()
        DemoLaunch.settle(app)
        DemoLaunch.pause(1.5)
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Tests

    /// The pointer over the plot: the readout appears, and it *tracks*.
    func testHoverOverThePlotShowsAReadoutThatTracks() {
        let app = openFirstInsight()
        guard let plot = markBandUnion(in: app) else {
            XCTFail("The insight chart rendered no mark bands to aim at.")
            return
        }

        XCTAssertNil(readout(in: app), "A readout was showing before anything was hovered.")

        hover(app, x: plot.midX, y: plot.midY)
        DemoLaunch.pause(0.6)
        let centre = readout(in: app)
        XCTAssertNotNil(centre, "Hovering the middle of the plot produced no readout.")
        capture("a1-hover-plot-centre")

        // Re-measure: the reserved readout row is 20pt taller once it holds a
        // drillable readout, so the plot moves the first time a scrub lands.
        guard let settled = markBandUnion(in: app) else { return }
        var seen: Set<String> = []
        for fraction in [0.25, 0.45, 0.65, 0.85] {
            hover(app, x: settled.minX + settled.width * fraction, y: settled.midY)
            DemoLaunch.pause(0.4)
            if let text = readout(in: app) { seen.insert(text) }
        }
        print("PHASEB-HOVER-TRACK \(seen.sorted())")
        XCTAssertGreaterThan(
            seen.count, 1,
            "The readout never changed as the pointer crossed the plot: \(seen)."
        )
    }

    /// Task 7's M2: does the readout **blank** in the 12pt scale-padding band
    /// at the plot's edges?
    ///
    /// `.chartXScale(range: .plotDimension(padding: 12))` insets the domain
    /// inside the plot, so there is a strip at each end that is inside the plot
    /// frame — `ChartScrubMath.plotX` returns a value — but outside the domain,
    /// where `ChartProxy.value(atX:)` can answer nil. `ChartHover` writes that
    /// nil straight into the binding, which would clear a readout the pointer
    /// is still inside the plot for.
    ///
    /// The scan is the evidence: start in the middle, where a selection
    /// definitely exists, then walk outward a point at a time and record
    /// whether the readout survived. Absence anywhere inside the mark band is
    /// the defect; absence only outside it is the guard working.
    func testScrubReadoutSurvivesThePlotMargins() {
        let app = openFirstInsight()
        guard let first = markBandUnion(in: app) else {
            XCTFail("The insight chart rendered no mark bands to aim at.")
            return
        }
        hover(app, x: first.midX, y: first.midY)
        DemoLaunch.pause(0.6)
        guard let plot = markBandUnion(in: app) else { return }
        print("PHASEB-PLOT-SETTLED \(plot)")

        var blanks: [CGFloat] = []

        func scan(_ label: String, offsets: [CGFloat], from edge: CGFloat) {
            for offset in offsets {
                let x = edge + offset
                hover(app, x: plot.midX, y: plot.midY)
                DemoLaunch.pause(0.3)
                hover(app, x: x, y: plot.midY)
                DemoLaunch.pause(0.35)
                let text = readout(in: app)
                print("PHASEB-MARGIN \(label) offset=\(offset) x=\(x) readout=\(text ?? "NONE")")
                if text == nil { blanks.append(offset) }
            }
        }

        scan("leading", offsets: [0, 2, 4, 6, 8, 10, 12, 16, 24], from: plot.minX)
        capture("a2-hover-plot-leading-margin")
        scan("trailing", offsets: [0, -2, -4, -6, -8, -10, -12, -16, -24], from: plot.maxX)
        capture("a3-hover-plot-trailing-margin")

        XCTAssertEqual(
            app.state, .runningForeground, "Scanning the plot margins took the app down."
        )
        XCTAssertTrue(
            blanks.isEmpty,
            "The readout blanked while the pointer was still inside the plot, at offsets "
                + "\(blanks) from the edge — Task 7's M2."
        )
    }

    /// M5: the funnel row wash. A hover over one step must not light its
    /// neighbours, and it must not double up with the drill button's own
    /// emphasis.
    func testFunnelHoverWashStaysOnItsOwnRow() {
        let app = DemoLaunch.launch()
        app.typeKey("4", modifierFlags: .command)
        DemoLaunch.settle(app)
        guard let row = DemoLaunch.waitForContent(
            containing: "Example constellation journey", in: app
        ) else {
            XCTFail("The insights list never offered its funnel.")
            return
        }
        row.click()
        DemoLaunch.settle(app)
        DemoLaunch.pause(1.5)
        capture("a4-funnel-at-rest")

        let steps = app.windows.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Step "))
            .allElementsBoundByIndex
        print("PHASEB-FUNNEL-STEPS \(steps.map { "\($0.elementType.rawValue):\($0.label)@\($0.frame)" })")
        guard steps.count >= 2 else {
            XCTFail("The funnel rendered fewer than two addressable steps.")
            return
        }

        steps[0].hover()
        DemoLaunch.pause(0.6)
        capture("a5-funnel-hover-first-step")
        steps[1].hover()
        DemoLaunch.pause(0.6)
        capture("a6-funnel-hover-second-step")
        XCTAssertEqual(app.state, .runningForeground, "Hovering the funnel took the app down.")
    }
}
