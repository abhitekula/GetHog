import UIKit
import XCTest

@MainActor
final class TVNavigationTests: XCTestCase {
    func testSidebarRowsTakeFocusAndReachTheirScreens() {
        let destinations = [
            ("Insights", "Insights"),
            ("Events", "meteor_report_opened"),
            ("Sessions", "Alex Example,"),
            ("Flags", "example-navigation")
        ]

        for (title, fixture) in destinations {
            // Relaunch each walk at the shell's stable Dashboards focus. Once
            // a destination is selected, focus correctly moves into that
            // screen's content; repeatedly pressing Up is not a supported way
            // to reopen a `.sidebarAdaptable` sidebar on tvOS.
            let app = DemoLaunch.launch()
            TVSidebar.select(title, in: app)
            XCTAssertTrue(
                DemoLaunch.wait(for: app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fixture, fixture)
                ).firstMatch, timeout: 60),
                "Selecting the focused \(title) sidebar row did not reach its screen."
            )
        }
    }

    func testSettingsIsReachable() {
        let app = DemoLaunch.launch()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "Example App metric 33",
                    "Example App metric 33"
                )
            ).firstMatch, timeout: 60),
            "The walk to Settings did not start on the rendered Dashboards screen."
        )
        TVSidebar.select("Settings", in: app)

        XCTAssertTrue(DemoLaunch.wait(for: app.buttons["Sign out"], timeout: 60))
    }

    func testFlagDetailOmitsUnavailableWidgetAndControlCenterAffordances() {
        let app = DemoLaunch.launch()
        TVSidebar.select("Flags", in: app)
        let flag = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "example-navigation")
        ).firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: flag, timeout: 60))
        // `FlagWidgetTip` lives on the list, so verify its TV compile-out
        // before navigating away from that hierarchy.
        XCTAssertEqual(DemoLaunch.elements(labelled: "Keep a flag to hand", in: app).count, 0)
        // Right leaves the sidebar for the list; Down moves from the list
        // container onto its first focusable row. The row's combined
        // accessibility container does not report `hasFocus` reliably on
        // tvOS, so the detail assertion is the navigation oracle.
        TVRemote.press(.right)
        TVRemote.press(.down)
        TVRemote.press(.select)

        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["Live state"], timeout: 60))
        XCTAssertEqual(DemoLaunch.elements(labelled: "Allow quick toggle", in: app).count, 0)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Control Center")
            ).firstMatch.exists
        )
    }

    func testEventsOmitsSavedFilterAuthoringThatTVCannotPersist() {
        let app = DemoLaunch.launch()
        TVSidebar.select("Events", in: app)

        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["meteor_report_opened"], timeout: 60))
        XCTAssertEqual(DemoLaunch.elements(labelled: "Saved filters", in: app).count, 0)
        XCTAssertEqual(DemoLaunch.elements(labelled: "Save current filters", in: app).count, 0)
    }
}

@MainActor
final class TVScopeGuidanceUITests: XCTestCase {
    func testSettingsRendersOnlyTheWriteScopeTVCanUse() {
        let app = DemoLaunch.launch()
        TVSidebar.select("Settings", in: app)
        XCTAssertTrue(DemoLaunch.wait(for: app.buttons["Sign out"], timeout: 60))

        let requiredAction = "Toggle feature flags"
        let requiredScope = "feature_flag:write"
        let requiredPair = "\(requiredAction), \(requiredScope)"
        let unavailableRolloutPair = "Toggle feature flags and change rollouts, \(requiredScope)"
        let unavailableScopes = [
            "alert:write",
            "annotation:write",
            "error_tracking:write",
            "experiment:write",
            "survey:write",
        ]
        let requiredRows = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR value == %@",
                requiredPair,
                requiredPair
            )
        )
        let requiredRow = requiredRows.firstMatch
        let unavailableRolloutRows = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR value == %@",
                unavailableRolloutPair,
                unavailableRolloutPair
            )
        )

        XCTAssertTrue(
            DemoLaunch.wait(timeout: 60) {
                requiredRow.exists || unavailableRolloutRows.firstMatch.exists
            },
            "TV Settings did not render any feature-flag write-scope row."
        )
        XCTAssertTrue(
            requiredRow.exists,
            "TV Settings did not render the scope for its live feature-flag toggle."
        )
        XCTAssertFalse(
            unavailableRolloutRows.firstMatch.exists,
            "TV Settings reused the full-client rollout action copy."
        )
        for scope in unavailableScopes {
            XCTAssertEqual(
                app.descendants(matching: .any).matching(
                    NSPredicate(
                        format: "label CONTAINS %@ OR value CONTAINS %@",
                        scope,
                        scope
                    )
                ).count,
                0,
                "TV Settings advertised the unavailable \(scope) action."
            )
        }

        // Move into the Settings list and retain the first frame in which the
        // complete projected row is customer-visible, rather than accepting a
        // partially clipped accessibility match as rendered evidence.
        TVRemote.press(.right)
        let renderedRows = requiredRow.exists ? requiredRows : unavailableRolloutRows
        let renderedRow = renderedRows.firstMatch
        let visibleFrame = app.windows.firstMatch.frame.insetBy(dx: 16, dy: 16)
        var isFullyVisible = renderedRow.isHittable
            && visibleFrame.contains(renderedRow.frame)
        var remainingFocusMoves = 16
        while !isFullyVisible && remainingFocusMoves > 0 {
            TVRemote.press(.down)
            isFullyVisible = DemoLaunch.wait(timeout: 1) {
                renderedRow.isHittable && visibleFrame.contains(renderedRow.frame)
            }
            remainingFocusMoves -= 1
        }
        XCTAssertTrue(
            isFullyVisible,
            "The complete feature-flag scope row never became visible on screen."
        )
        let measuredPair = (0 ..< renderedRows.count)
            .map { renderedRows.element(boundBy: $0) }
            // The exact combined label appears on the full list row, its
            // measured pair, and a compact text node. Select the widest match
            // inside the full row: that is the 460pt/900pt layout container,
            // not the outer hit region or the text's intrinsic width.
            .filter {
                $0.exists
                    && $0.frame.width > 0
                    && $0.frame.width < renderedRow.frame.width
            }
            .max { $0.frame.width < $1.frame.width }
        XCTAssertNotNil(measuredPair, "TV Settings exposed no measurable action/scope pair.")
        if let measuredPair {
            XCTAssertGreaterThan(
                measuredPair.frame.width,
                800,
                "TV Settings retained the 460-point iPad pair cap instead of using the television row."
            )
            XCTAssertLessThan(
                measuredPair.frame.height,
                90,
                "The TV action/scope pair wrapped instead of keeping feature_flag:write on one line."
            )
        }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "TV Settings feature flag write scope"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

@MainActor
final class TVHogQLFocusTests: XCTestCase {
    private static let dashboardID = "725102"

    func testRemoteFocusRevealsAnOffscreenTableColumn() {
        let app = launchHogQLTile(index: 1)
        let dataCells = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "gethog.hogql-table.row.")
        )
        let trailingCells = dataCells.matching(
            NSPredicate(format: "identifier ENDSWITH %@", ".cell.11")
        )

        XCTAssertTrue(
            DemoLaunch.wait(until: { dataCells.count > 0 }),
            "The table never rendered an identified data cell."
        )
        XCTAssertTrue(
            TVRemote.focusAny(in: dataCells, by: .right, limit: 12),
            "The Siri Remote could not enter the HogQL table."
        )
        XCTAssertTrue(
            TVRemote.focusAny(in: trailingCells, by: .right, limit: 16),
            "Right presses did not move focus to the trailing HogQL table cell."
        )
        let focusedTrailingCell = TVRemote.focusedElement(in: trailingCells)
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                focusedTrailingCell.exists && focusedTrailingCell.isHittable
            }),
            "Focusing the trailing table cell did not reveal its offscreen column."
        )
    }

    func testRemoteFocusRevealsAnOffscreenHeatmapColumn() {
        let app = launchHogQLTile(index: 7)
        let firstCell = app.staticTexts["region-01, email: 1"].firstMatch
        let trailingCell = app.staticTexts["region-32, email: 32"].firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: firstCell), "The heatmap's first cell never rendered.")
        XCTAssertTrue(trailingCell.exists, "The deterministic trailing heatmap cell was absent.")
        XCTAssertTrue(
            TVRemote.focus(on: firstCell, by: .right, limit: 12),
            "The Siri Remote could not enter the HogQL heatmap."
        )
        XCTAssertTrue(
            TVRemote.focus(on: trailingCell, by: .right, limit: 36),
            "Right presses did not move focus to the trailing HogQL heatmap cell."
        )
        XCTAssertTrue(
            DemoLaunch.wait(until: { trailingCell.hasFocus && trailingCell.isHittable }),
            "Focusing the trailing heatmap cell did not reveal its offscreen column."
        )
    }

    private func launchHogQLTile(index: Int) -> XCUIApplication {
        DemoLaunch.launch(environment: [
            "GETHOG_OPEN_DASHBOARD": Self.dashboardID,
            "GETHOG_OPEN_TILE": String(index),
        ])
    }
}

@MainActor
final class TVDashboardPresentationTests: XCTestCase {
    private static let hogQLDashboardID = "725102"
    private static let emptyDashboardID = "725103"

    func testFocusedDashboardRowKeepsRenderedTitleDistinctFromItsBackground() throws {
        let app = DemoLaunch.launch()
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Example App metric 33")
        ).firstMatch
        let title = app.staticTexts["Example App metric 33"].firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: row), "The first dashboard row never rendered.")
        XCTAssertTrue(DemoLaunch.wait(for: title), "The first dashboard title never rendered.")
        // Dashboard rows combine their children and do not report `hasFocus`
        // on tvOS. The recording proves that Right enters the first row and
        // that the helper's first Down immediately overshot to the second row.
        TVRemote.press(.right)
        DemoLaunch.settle(app)

        let screenshot = XCUIScreen.main.screenshot().image
        let focusSurfaceFrame = CGRect(
            x: row.frame.maxX - 96,
            y: row.frame.midY - 12,
            width: 32,
            height: 24
        )
        let focusSurfaceLuminance = try XCTUnwrap(
            TVRenderedPixelOracle.medianLuminance(
                in: screenshot,
                frame: focusSurfaceFrame,
                appFrame: app.frame
            ),
            "The first dashboard row's focused surface could not be sampled."
        )
        XCTAssertGreaterThan(
            focusSurfaceLuminance,
            0.70,
            "Right did not leave the native bright focus surface on the first dashboard row."
        )

        let contrastSpan = try XCTUnwrap(
            TVRenderedPixelOracle.luminanceSpan(
                in: screenshot,
                frame: title.frame,
                appFrame: app.frame
            ),
            "The focused dashboard title could not be sampled from the rendered screenshot."
        )
        XCTAssertGreaterThan(
            contrastSpan,
            0.30,
            "The focused dashboard title merged into its rendered row background."
        )
    }

    func testFocusScrollingKeepsDashboardContentBelowNavigationTitle() {
        let app = launchHogQLTile(index: 1)
        let title = app.staticTexts["Synthetic HogQL gallery"].firstMatch
        let savedRange = app.buttons["Saved"].firstMatch
        let tableCard = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Synthetic result table")
        ).firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: title), "The dashboard navigation title never rendered.")
        XCTAssertTrue(DemoLaunch.wait(for: savedRange), "The dashboard range picker never rendered.")
        XCTAssertTrue(DemoLaunch.wait(for: tableCard), "The dashboard card never rendered.")

        // This is the shortest reproduced Siri Remote route: focus movement
        // scrolls the grid, and used to pull both the range row and the first
        // card underneath the large navigation title.
        TVRemote.press(.right)
        TVRemote.press(.down)
        DemoLaunch.settle(app)

        let chromeBottom = title.frame.maxY
        XCTAssertGreaterThanOrEqual(
            savedRange.frame.minY,
            chromeBottom + 8,
            "Focus scrolling pulled the range picker underneath the navigation title."
        )
        XCTAssertGreaterThanOrEqual(
            tableCard.frame.minY,
            chromeBottom + 8,
            "Focus scrolling pulled dashboard content underneath the navigation title."
        )
    }

    func testMenuDismissesInspectorBeforePoppingDashboard() {
        let app = launchHogQLTile(index: 1)
        let close = app.buttons["Close insight"].firstMatch
        let savedRange = app.buttons["Saved"].firstMatch
        let inspectorCells = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "gethog.hogql-table.row.")
        )

        XCTAssertTrue(DemoLaunch.wait(for: close), "The dashboard inspector never opened.")
        XCTAssertTrue(DemoLaunch.wait(for: savedRange), "The dashboard detail never rendered.")
        XCTAssertTrue(
            DemoLaunch.wait(until: { inspectorCells.count > 0 }),
            "The inspector's identified HogQL cells never rendered."
        )
        XCTAssertTrue(
            TVRemote.focusAny(in: inspectorCells, by: .right, limit: 12),
            "The Siri Remote could not move focus from the sidebar into the inspector."
        )
        let focusedInspectorCell = TVRemote.focusedElement(in: inspectorCells)
        XCTAssertTrue(
            focusedInspectorCell.exists && focusedInspectorCell.hasFocus,
            "No identified inspector cell held focus before Menu was pressed."
        )
        TVRemote.press(.menu)

        XCTAssertTrue(
            DemoLaunch.wait(until: { !close.exists }),
            "Menu did not dismiss the dashboard inspector."
        )
        XCTAssertTrue(
            savedRange.exists && savedRange.isHittable,
            "Menu popped the dashboard detail instead of dismissing its inspector first."
        )
    }

    func testNonSavedRangeShowsBoundedLabelledCompareControl() throws {
        let app = DemoLaunch.launch(environment: [
            "GETHOG_OPEN_DASHBOARD": Self.emptyDashboardID,
        ])
        let savedRange = app.buttons["Saved"].firstMatch
        let dayRange = app.buttons["24h"].firstMatch
        let emptyState = app.staticTexts["No tiles on this dashboard"].firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: savedRange), "The dashboard range picker never rendered.")
        XCTAssertTrue(DemoLaunch.wait(for: dayRange), "The 24h range never rendered.")
        XCTAssertTrue(
            DemoLaunch.wait(for: emptyState),
            "The empty dashboard did not settle before the focus route began."
        )
        XCTAssertTrue(savedRange.isSelected, "The dashboard did not start on its Saved range.")

        // Deep launch begins on the Dashboards sidebar item. The first Right
        // enters the settled empty dashboard's segmented picker; the next
        // selects 24h. `isSelected` is the reliable state oracle here because
        // segmented picker buttons, like dashboard rows, omit `hasFocus`.
        var remainingRightPresses = 2
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 3) {
                if dayRange.isSelected { return true }
                guard remainingRightPresses > 0 else { return false }
                TVRemote.press(.right)
                remainingRightPresses -= 1
                return dayRange.isSelected
            },
            "The Siri Remote did not select the non-Saved 24h range."
        )

        let compare = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Compare to the previous period")
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: compare, timeout: 5),
            "A non-Saved range did not reveal the compare control."
        )
        XCTAssertLessThanOrEqual(
            compare.frame.width,
            560,
            "The compare control stretched across the dashboard instead of remaining bounded."
        )

        let insetCompareFrame = compare.frame.insetBy(dx: 16, dy: 10)
        let labelFrame = CGRect(
            x: insetCompareFrame.minX,
            y: insetCompareFrame.minY,
            width: insetCompareFrame.width * 0.72,
            height: insetCompareFrame.height
        )
        let labelSpan = try XCTUnwrap(
            TVRenderedPixelOracle.luminanceSpan(
                in: XCUIScreen.main.screenshot().image,
                frame: labelFrame,
                appFrame: app.frame
            ),
            "The compare control's label region could not be sampled from the screenshot."
        )
        XCTAssertGreaterThan(
            labelSpan,
            0.25,
            "The compare control had no readable rendered label."
        )
    }

    private func launchHogQLTile(index: Int) -> XCUIApplication {
        DemoLaunch.launch(environment: [
            "GETHOG_OPEN_DASHBOARD": Self.hogQLDashboardID,
            "GETHOG_OPEN_TILE": String(index),
        ])
    }
}

@MainActor
private enum TVRenderedPixelOracle {
    static func medianLuminance(
        in image: UIImage,
        frame: CGRect,
        appFrame: CGRect
    ) -> Double? {
        sampledLuminances(in: image, frame: frame, appFrame: appFrame).map {
            $0[$0.count / 2]
        }
    }

    static func luminanceSpan(
        in image: UIImage,
        frame: CGRect,
        appFrame: CGRect
    ) -> Double? {
        sampledLuminances(in: image, frame: frame, appFrame: appFrame).map { luminances in
            let last = luminances.count - 1
            let low = luminances[Int(Double(last) * 0.02)]
            let high = luminances[Int(Double(last) * 0.98)]
            return high - low
        }
    }

    private static func sampledLuminances(
        in image: UIImage,
        frame: CGRect,
        appFrame: CGRect
    ) -> [Double]? {
        guard
            let source = image.cgImage,
            appFrame.width > 0,
            appFrame.height > 0,
            frame.width > 0,
            frame.height > 0
        else { return nil }

        let scaleX = CGFloat(source.width) / appFrame.width
        let scaleY = CGFloat(source.height) / appFrame.height
        let sampleRect = CGRect(
            x: (frame.minX - appFrame.minX) * scaleX,
            y: (frame.minY - appFrame.minY) * scaleY,
            width: frame.width * scaleX,
            height: frame.height * scaleY
        ).integral.intersection(
            CGRect(x: 0, y: 0, width: source.width, height: source.height)
        )
        guard
            sampleRect.width >= 2,
            sampleRect.height >= 2,
            let crop = source.cropping(to: sampleRect)
        else { return nil }

        let width = crop.width
        let height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var luminances: [Double] = []
        luminances.reserveCapacity(width * height / 4)
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let index = ((y * width) + x) * 4
                let red = Double(pixels[index]) / 255
                let green = Double(pixels[index + 1]) / 255
                let blue = Double(pixels[index + 2]) / 255
                luminances.append((0.2126 * red) + (0.7152 * green) + (0.0722 * blue))
            }
        }
        guard luminances.count >= 2 else { return nil }

        luminances.sort()
        return luminances
    }
}
