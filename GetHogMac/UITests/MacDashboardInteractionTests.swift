import XCTest

final class MacDashboardInteractionTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func changedPixelCount(
        from before: XCUIScreenshot,
        to after: XCUIScreenshot,
        in region: CGRect,
        screenFrame: CGRect
    ) throws -> Int {
        var beforeRect = CGRect(origin: .zero, size: before.image.size)
        var afterRect = CGRect(origin: .zero, size: after.image.size)
        let beforeImage = try XCTUnwrap(
            before.image.cgImage(forProposedRect: &beforeRect, context: nil, hints: nil)
        )
        let afterImage = try XCTUnwrap(
            after.image.cgImage(forProposedRect: &afterRect, context: nil, hints: nil)
        )
        let scaleX = CGFloat(beforeImage.width) / screenFrame.width
        let scaleY = CGFloat(beforeImage.height) / screenFrame.height
        let pixelRegion = CGRect(
            x: (region.minX - screenFrame.minX) * scaleX,
            y: (region.minY - screenFrame.minY) * scaleY,
            width: region.width * scaleX,
            height: region.height * scaleY
        ).integral
        let beforeCrop = try XCTUnwrap(beforeImage.cropping(to: pixelRegion))
        let afterCrop = try XCTUnwrap(afterImage.cropping(to: pixelRegion))
        let width = beforeCrop.width
        let height = beforeCrop.height
        let bytesPerRow = width * 4
        var beforeBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        var afterBytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        func draw(_ image: CGImage, into bytes: inout [UInt8]) throws {
            let context = try XCTUnwrap(
                CGContext(
                    data: &bytes,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        try draw(beforeCrop, into: &beforeBytes)
        try draw(afterCrop, into: &afterBytes)
        return stride(from: 0, to: beforeBytes.count, by: 4).reduce(into: 0) { count, index in
            let changed = (0..<3).contains { channel in
                abs(Int(beforeBytes[index + channel]) - Int(afterBytes[index + channel])) >= 12
            }
            if changed { count += 1 }
        }
    }

    private func firstDashboardCard(in app: XCUIApplication) -> XCUIElement? {
        let hub = app.scrollViews["gethog.dashboard-hub"].firstMatch
        guard DemoLaunch.wait(for: hub) else {
            XCTFail("The dashboard landing did not expose its hub.")
            return nil
        }
        let card = app.buttons["gethog.dashboard-card.725101"].firstMatch
        for _ in 0..<12 where !(card.exists && card.isHittable) {
            hub.scroll(byDeltaX: 0, deltaY: -180)
            DemoLaunch.pause(0.2)
        }
        guard DemoLaunch.wait(until: { card.exists && card.isHittable }) else {
            XCTFail("The dashboard hub never exposed gethog.dashboard-card.725101.")
            return nil
        }
        return card
    }

    @MainActor
    func testRecentlyComputedDashboardOpensItsDetail() {
        let app = DemoLaunch.launch(tab: "dashboards")
        let recent = app.buttons["gethog.dashboard-recent-card.725101"].firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: recent))
        recent.click()

        let detail = app.descendants(matching: .any)["gethog.dashboard-detail.725101"]
        XCTAssertTrue(DemoLaunch.wait(for: detail))
        let actions = DemoLaunch.elements(labelled: "Dashboard actions", in: app).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: actions))
    }

    @MainActor
    func testDashboardSearchDoesNotLeaveAnUnmatchedRecentCard() {
        let app = DemoLaunch.launch(tab: "dashboards")
        let search = app.searchFields.firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: search))
        search.click()
        search.typeText("definitely-no-dashboard")

        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["No matching dashboards"]))
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "gethog.dashboard-recent-card."
                )
            ).firstMatch.exists
        )
    }

    @MainActor
    func testDashboardCardShowsPointerFeedbackWithoutLosingActivation() throws {
        let app = DemoLaunch.launch(tab: "dashboards")
        guard let card = firstDashboardCard(in: app) else { return }
        let window = app.windows.firstMatch
        XCTAssertTrue(card.isHittable, "The dashboard card was not hittable before hover.")
        let before = window.screenshot()

        card.hover()
        DemoLaunch.pause(0.4)
        let hovered = window.screenshot()
        capture("dashboard-card-hover")
        XCTAssertTrue(card.isHittable, "Entering the dashboard card disabled its activation.")

        // Narrow perimeter bands capture the semantic outline without being
        // fooled by static card content in the centre.
        let frame = card.frame.insetBy(dx: 1, dy: 1)
        let band: CGFloat = 4
        let perimeter = [
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: band),
            CGRect(x: frame.minX, y: frame.maxY - band, width: frame.width, height: band),
            CGRect(x: frame.minX, y: frame.minY + band, width: band, height: frame.height - 2 * band),
            CGRect(
                x: frame.maxX - band,
                y: frame.minY + band,
                width: band,
                height: frame.height - 2 * band
            ),
        ]
        let changed = try perimeter.reduce(into: 0) { count, region in
            count += try changedPixelCount(
                from: before,
                to: hovered,
                in: region,
                screenFrame: window.frame
            )
        }
        XCTAssertGreaterThan(
            changed,
            40,
            "Hovering the dashboard card changed only \(changed) pixels; no visible pointer outline appeared."
        )

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.04)).hover()
        DemoLaunch.pause(0.3)
        XCTAssertTrue(card.isHittable, "Leaving the dashboard card disabled its activation.")
    }
}
