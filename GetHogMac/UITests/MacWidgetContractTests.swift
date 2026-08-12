import XCTest

/// Live WidgetKit acceptance for a disposable macOS VM.
///
/// This suite intentionally does not launch GetHog first: the system gallery
/// and installed widget are the product under test. Set
/// `GETHOG_WIDGET_SYSTEM_UI=1` only on the disposable CUA runner. A normal UI
/// run skips these methods rather than adding, resizing, or reconfiguring a
/// developer's real widgets.
final class MacWidgetContractTests: XCTestCase {

    private struct Variant {
        let widget: String
        let family: String
    }

    private static let variants = [
        Variant(widget: "Metric", family: "Small"),
        Variant(widget: "Metric", family: "Medium"),
        Variant(widget: "Metric", family: "Large"),
        Variant(widget: "Project Health", family: "Small"),
        Variant(widget: "Project Health", family: "Medium"),
        Variant(widget: "Project Health", family: "Large"),
        Variant(widget: "Feature Flag", family: "Small"),
        Variant(widget: "Feature Flag", family: "Medium"),
    ]

    @MainActor private var notificationCenter: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
    }

    @MainActor private var controlCenter: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.controlcenter")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["GETHOG_WIDGET_SYSTEM_UI"] == "1" else {
            throw XCTSkip("Requires the disposable macOS CUA widget runner.")
        }
    }

    /// Catches a bundle that registers fewer than the promised 3 Metric,
    /// 3 Health, and 2 Flag variants, or whose display names make it
    /// undiscoverable under GetHog.
    @MainActor
    func testGalleryDiscoversAllEightFamilyPreviews() {
        openGallery()
        defer { closeGalleryIfOpen() }

        XCTAssertEqual(Self.variants.count, 8)
        var previewFingerprints = Set<String>()
        for variant in Self.variants {
            let preview = galleryPreview(variant)
            XCTAssertTrue(
                DemoLaunch.wait(for: preview, timeout: 10),
                "The GetHog gallery did not expose \(variant.widget) in \(variant.family)."
            )
            let fingerprint = "\(preview.elementType.rawValue)|\(preview.label)|\(preview.value ?? "")|\(preview.frame)"
            XCTAssertTrue(
                previewFingerprints.insert(fingerprint).inserted,
                "\(variant.widget) \(variant.family) reused another gallery preview instead of a distinct family item."
            )
        }
        XCTAssertEqual(previewFingerprints.count, 8)
    }

    /// Catches a gallery-only implementation: each widget must install, expose
    /// exactly its supported native resize choices, offer configuration where
    /// the WidgetConfigurationIntent declares it, tell the truth in a teamless
    /// Debug build, and foreground the host app when opened.
    @MainActor
    func testInstalledDebugWidgetsResizeConfigureAndOpenGetHog() {
        openNotificationCenter()
        removeInstalledWidgets()
        defer { removeInstalledWidgets() }

        openGallery()
        install(widget: "Metric")
        install(widget: "Project Health")
        install(widget: "Feature Flag")
        closeGallery()

        assertResizeFamilies(widget: "Metric", expected: ["Small", "Medium", "Large"])
        assertResizeFamilies(widget: "Project Health", expected: ["Small", "Medium", "Large"])
        assertResizeFamilies(widget: "Feature Flag", expected: ["Small", "Medium"])

        assertConfiguration(widget: "Metric", parameter: "Metric")
        assertConfiguration(widget: "Feature Flag", parameter: "Feature Flag")

        let unshared = text("Open GetHog to connect. This build can't share data with widgets.")
        XCTAssertTrue(
            DemoLaunch.wait(for: unshared, timeout: 15),
            "The teamless Debug widget did not disclose its unshared container."
        )

        let host = XCUIApplication(bundleIdentifier: "app.gethog.GetHog")
        if host.state != .notRunning { host.terminate() }
        installedWidget(named: "Metric").click()
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 20) { host.state == .runningForeground },
            "Opening the installed widget did not foreground GetHog."
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: host.windows.descendants(matching: .any)
                .matching(DemoLaunch.macTextPredicate("Dashboards"))
                .firstMatch),
            "The widget launch did not reach GetHog's routed app shell."
        )
    }

    /// Signed sharing is a distinct acceptance path. It is enabled only when
    /// the runner has a genuinely signed Distribution app/extension pair. The
    /// method launches that app against committed DemoTransport data; the app's
    /// real publication path writes the snapshot and reloads WidgetKit before
    /// the method installs the widget. No live value or screenshot is committed.
    @MainActor
    func testSignedDistributionWidgetShowsTheAppSnapshotWhenAvailable() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GETHOG_WIDGET_SIGNED_DISTRIBUTION"] == "1" else {
            throw XCTSkip("No signed Distribution app/extension pair was supplied.")
        }
        let expectedMetric = "Example daily engagement"
        let expectedFreshness = "Updated now ago"
        let expectedDashboard = "Example App metric 33"

        let writer = XCUIApplication(bundleIdentifier: "app.gethog.GetHog")
        writer.launchArguments = ["-GetHogDemo"]
        writer.launchEnvironment["GETHOG_DEMO"] = "1"
        writer.launch()
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: expectedDashboard, in: writer, timeout: 30),
            "The signed app did not finish the deterministic publication path before widget installation."
        )
        writer.terminate()

        openNotificationCenter()
        removeInstalledWidgets(named: ["Metric"])
        defer { removeInstalledWidgets(named: ["Metric"]) }

        openGallery()
        install(widget: "Metric")
        closeGallery()

        let metricWidget = installedWidget(named: "Metric")
        XCTAssertTrue(DemoLaunch.wait(for: metricWidget, timeout: 10), "The signed Metric widget was not installed.")
        XCTAssertTrue(
            DemoLaunch.wait(for: text(expectedMetric, in: metricWidget), timeout: 20),
            "The signed widget did not show the synthetic metric written by the app."
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: text(expectedFreshness, in: metricWidget), timeout: 20),
            "The signed widget did not show the app snapshot's expected freshness."
        )
        XCTAssertFalse(
            text("Open GetHog to connect. This build can't share data with widgets.", in: metricWidget).exists,
            "A signed shared-container widget rendered the Debug-only unshared state."
        )

        let host = XCUIApplication(bundleIdentifier: "app.gethog.GetHog")
        if host.state != .notRunning { host.terminate() }
        metricWidget.click()
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 20) { host.state == .runningForeground },
            "Opening the populated signed widget did not foreground GetHog."
        )
        let dashboardDetail = host.descendants(matching: .any)
            .matching(identifier: "gethog.dashboard-detail.725101")
            .firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: dashboardDetail, timeout: 30),
            "The populated signed widget did not deep-link to dashboard 725101 (\(expectedDashboard))."
        )
    }

    // MARK: - Gallery

    @MainActor
    private func openNotificationCenter() {
        let existingEdit = firstElement(
            containingAny: ["Edit Widgets", "Add Widgets"],
            in: notificationCenter
        )
        if existingEdit.exists, existingEdit.isHittable { return }

        controlCenter.activate()
        let notificationToggle = firstElement(
            containingAny: ["Notification Center", "Clock"],
            in: controlCenter
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: notificationToggle, timeout: 10),
            "Control Center exposed neither its Clock nor Notification Center control."
        )
        notificationToggle.click()
    }

    @MainActor
    private func openGallery() {
        openNotificationCenter()
        let edit = firstElement(containingAny: ["Edit Widgets", "Add Widgets"], in: notificationCenter)
        XCTAssertTrue(
            DemoLaunch.wait(for: edit, timeout: 10),
            "Notification Center offered no native widget-gallery action."
        )
        edit.click()

        let search = notificationCenter.searchFields.firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: search, timeout: 10), "The widget gallery has no search field.")
        search.click()
        search.typeText("GetHog")

        let getHog = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "GetHog", "GetHog")
        let buttonResult = notificationCenter.buttons.matching(getHog).firstMatch
        let cellResult = notificationCenter.cells.matching(getHog).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 10) { buttonResult.exists || cellResult.exists },
            "GetHog is absent from the widget gallery."
        )
        let result = buttonResult.exists ? buttonResult : cellResult
        XCTAssertTrue(result.isHittable, "The GetHog gallery result exists but cannot be selected.")
        result.click()
    }

    @MainActor
    private func galleryPreview(_ variant: Variant) -> XCUIElement {
        notificationCenter.descendants(matching: .any).matching(NSPredicate(
            format: "(label CONTAINS[c] %@ AND label CONTAINS[c] %@) "
                + "OR (value CONTAINS[c] %@ AND value CONTAINS[c] %@)",
            variant.widget,
            variant.family,
            variant.widget,
            variant.family
        )).firstMatch
    }

    @MainActor
    private func install(widget name: String) {
        guard let variant = Self.variants.first(where: { $0.widget == name }) else {
            return XCTFail("The authored gallery contract has no \(name) variant.")
        }
        let preview = galleryPreview(variant)
        XCTAssertTrue(DemoLaunch.wait(for: preview, timeout: 10), "No \(name) preview was installable.")
        preview.click()

        let add = firstElement(containingAny: ["Add Widget"], in: notificationCenter)
        XCTAssertTrue(DemoLaunch.wait(for: add, timeout: 10), "The \(name) preview had no Add Widget action.")
        add.click()
    }

    @MainActor
    private func closeGallery() {
        let done = firstElement(containingAny: ["Done", "Close"], in: notificationCenter)
        XCTAssertTrue(DemoLaunch.wait(for: done, timeout: 10), "The widget gallery had no Done action.")
        done.click()
    }

    @MainActor
    private func closeGalleryIfOpen() {
        let done = firstElement(containingAny: ["Done", "Close"], in: notificationCenter)
        if done.exists, done.isHittable { done.click() }
    }

    // MARK: - Installed widgets

    @MainActor
    private func assertResizeFamilies(widget name: String, expected: [String]) {
        for family in expected {
            let widget = installedWidget(named: name)
            XCTAssertTrue(DemoLaunch.wait(for: widget, timeout: 10), "The \(name) widget was not installed.")
            widget.rightClick()
            let size = notificationCenter.menuItems[family]
            XCTAssertTrue(
                DemoLaunch.wait(for: size, timeout: 5),
                "The installed \(name) widget offered no native \(family) resize."
            )
            size.click()
        }

        if expected == ["Small", "Medium"] {
            installedWidget(named: name).rightClick()
            XCTAssertFalse(
                notificationCenter.menuItems["Large"].exists,
                "The Feature Flag widget offered its unsupported Large family."
            )
            notificationCenter.typeKey(.escape, modifierFlags: [])
        }
    }

    @MainActor
    private func assertConfiguration(widget name: String, parameter: String) {
        installedWidget(named: name).rightClick()
        let edit = firstElement(containingAny: ["Edit Widget", "Configure Widget"], in: notificationCenter)
        XCTAssertTrue(DemoLaunch.wait(for: edit, timeout: 5), "The \(name) widget was not configurable.")
        edit.click()

        let popover = notificationCenter.popovers.firstMatch
        let sheet = notificationCenter.sheets.firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 5) { popover.exists || sheet.exists },
            "The \(name) Edit Widget action opened no configuration container."
        )
        let editor = popover.exists ? popover : sheet
        let field = editor.descendants(matching: .any).matching(NSPredicate(
            format: "(label CONTAINS[c] %@ OR value CONTAINS[c] %@) "
                + "AND (elementType == %@ OR elementType == %@ OR elementType == %@)",
            parameter,
            parameter,
            NSNumber(value: XCUIElement.ElementType.button.rawValue),
            NSNumber(value: XCUIElement.ElementType.popUpButton.rawValue),
            NSNumber(value: XCUIElement.ElementType.comboBox.rawValue)
        )).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: field, timeout: 5),
            "The \(name) configuration UI did not expose an interactive \(parameter) control."
        )
        notificationCenter.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func installedWidget(named name: String) -> XCUIElement {
        firstElement(containingAny: [name], in: notificationCenter)
    }

    @MainActor
    private func text(_ value: String) -> XCUIElement {
        text(value, in: notificationCenter)
    }

    @MainActor
    private func text(_ value: String, in container: XCUIElement) -> XCUIElement {
        container.staticTexts.matching(NSPredicate(
            format: "label == %@ OR value == %@",
            value,
            value
        )).firstMatch
    }

    @MainActor
    private func removeInstalledWidgets(named names: [String] = ["Metric", "Project Health", "Feature Flag"]) {
        openNotificationCenter()
        for name in names {
            for _ in 0..<4 {
                let widget = installedWidget(named: name)
                guard widget.exists else { break }
                widget.rightClick()
                let remove = firstElement(containingAny: ["Remove Widget"], in: notificationCenter)
                guard DemoLaunch.wait(for: remove, timeout: 3) else {
                    notificationCenter.typeKey(.escape, modifierFlags: [])
                    break
                }
                remove.click()
                let confirm = firstElement(containingAny: ["Remove"], in: notificationCenter)
                if DemoLaunch.wait(for: confirm, timeout: 2), confirm.isHittable { confirm.click() }
            }
        }
    }

    @MainActor
    private func firstElement(containingAny values: [String], in app: XCUIElement) -> XCUIElement {
        let predicates = values.map {
            "label CONTAINS[c] '\($0.replacingOccurrences(of: "'", with: "''"))' "
                + "OR value CONTAINS[c] '\($0.replacingOccurrences(of: "'", with: "''"))'"
        }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: predicates.map { "(\($0))" }.joined(separator: " OR ")))
            .firstMatch
    }
}
