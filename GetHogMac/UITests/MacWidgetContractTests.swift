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

    private struct InstalledCandidate {
        let element: XCUIElement
        let identity: String
        let area: CGFloat
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
        defer { closeGalleryIfOpen() }
        openGallery()

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
        cleanupInstalledWidgets()
        defer { cleanupInstalledWidgets() }

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

        let metricWidget = installedWidget(named: "Metric")
        let unshared = text(
            "Open GetHog to connect. This build can't share data with widgets.",
            in: metricWidget
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: unshared, timeout: 15),
            "The teamless Debug widget did not disclose its unshared container."
        )

        let host = XCUIApplication(bundleIdentifier: "app.gethog.GetHog")
        if host.state != .notRunning { host.terminate() }
        metricWidget.click()
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
    /// method first inspects the resolved built signatures and entitlements,
    /// then launches the narrow Release acceptance seam. The seam accepts no
    /// payload or credential: it replaces stale state with fixed fiction tagged
    /// by a fresh run UUID and signals only after write + reload completes.
    @MainActor
    func testSignedDistributionWidgetShowsTheAppSnapshotWhenAvailable() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GETHOG_WIDGET_SIGNED_DISTRIBUTION"] == "1" else {
            throw XCTSkip("No signed Distribution app/extension pair was supplied.")
        }
        let preflight = try SignedWidgetDistributionVerifier.verify(
            testBundleURL: Bundle(for: Self.self).bundleURL
        )
        XCTAssertTrue(preflight.isAccepted, preflight.report)

        let runID = UUID().uuidString.lowercased()
        let expectedMetric = "Signed widget acceptance \(runID.prefix(8))"
        let expectedFreshness = "Updated now ago"
        let expectedDashboard = "Example App metric 33"

        let writer = XCUIApplication(bundleIdentifier: "app.gethog.GetHog")
        writer.launchArguments = ["-GetHogSignedWidgetAcceptance"]
        writer.launchEnvironment = acceptanceLaunchEnvironment(runID: runID)
        writer.launch()
        defer { writer.terminate() }
        let completion = writer.descendants(matching: .any)
            .matching(identifier: "gethog.widget-acceptance.complete.\(runID)")
            .firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: completion, timeout: 30),
            "The signed app emitted no matching post-write, post-reload completion witness."
        )

        cleanupInstalledWidgets(named: ["Metric"])
        defer { cleanupInstalledWidgets(named: ["Metric"]) }

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

        metricWidget.click()
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 20) { writer.state == .runningForeground },
            "Opening the populated signed widget did not foreground GetHog."
        )
        let dashboardDetail = writer.descendants(matching: .any)
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
        let nativeSizes = ["Small", "Medium", "Large", "Extra Large"]
        let initialMenu = installedWidgetMenu(named: name)
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 5) {
                nativeSizes.contains { initialMenu.menuItems[$0].exists }
            },
            "The installed \(name) widget opened no native resize menu."
        )
        let actual = Set(nativeSizes.filter { initialMenu.menuItems[$0].exists })
        XCTAssertEqual(
            actual,
            Set(expected),
            "The installed \(name) widget's complete native resize set was \(actual.sorted())."
        )
        closeMenus()

        for family in expected {
            let menu = installedWidgetMenu(named: name)
            let size = menu.menuItems[family]
            XCTAssertTrue(
                DemoLaunch.wait(for: size, timeout: 5),
                "The installed \(name) widget offered no native \(family) resize."
            )
            size.click()
        }

    }

    @MainActor
    private func assertConfiguration(widget name: String, parameter: String) {
        let menu = installedWidgetMenu(named: name)
        let edit = firstElement(containingAny: ["Edit Widget", "Configure Widget"], in: menu)
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
    private func installedWidget(named name: String, required: Bool = true) -> XCUIElement {
        guard closeMenus() else {
            if required {
                XCTFail("Could not close existing Notification Center menus before resolving \(name).")
            }
            return missingInstalledWidget(named: name)
        }
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            name,
            name
        )
        let excludedTypes: Set<XCUIElement.ElementType> = [
            .application, .window, .sheet, .popover, .scrollView,
            .searchField, .menu, .menuItem,
        ]
        var deduplicated: [String: InstalledCandidate] = [:]

        for element in notificationCenter.descendants(matching: .any)
            .matching(predicate).allElementsBoundByIndex
        where element.exists && element.isHittable && !excludedTypes.contains(element.elementType) {
            let frame = element.frame
            guard frame.width > 0, frame.height > 0 else { continue }
            let identity = installedIdentity(for: element)
            let candidate = InstalledCandidate(
                element: element,
                identity: identity,
                area: frame.width * frame.height
            )
            if let existing = deduplicated[identity], existing.area <= candidate.area {
                continue
            }
            deduplicated[identity] = candidate
        }

        var witnessed: [InstalledCandidate] = []
        for candidate in deduplicated.values.sorted(by: candidateOrder) {
            if freshInstalledWidgetMenu(for: candidate.element) != nil {
                witnessed.append(candidate)
                closeMenus()
            }
        }
        let minimumArea = witnessed.map(\.area).min()
        let minimal = minimumArea.map { area in
            witnessed.filter { abs($0.area - area) < 0.5 }
        } ?? []

        if required || !witnessed.isEmpty {
            XCTAssertEqual(
                minimal.count,
                1,
                "Expected one minimal authored \(name) descendant with a fresh native Remove Widget menu; "
                    + "found \(minimal.count) minimal among \(witnessed.count) witnessed identities."
            )
        }
        if let candidate = minimal.first {
            return candidate.element
        }
        // The uniqueness assertion above carries the actionable failure; keep
        // the fallback rooted in Notification Center and guaranteed missing.
        return missingInstalledWidget(named: name)
    }

    @MainActor
    private func missingInstalledWidget(named name: String) -> XCUIElement {
        firstElement(
            containingAny: ["__missing-installed-widget-\(name)__"],
            in: notificationCenter
        )
    }

    @MainActor
    private func installedWidgetMenu(named name: String) -> XCUIElement {
        let widget = installedWidget(named: name)
        XCTAssertTrue(DemoLaunch.wait(for: widget, timeout: 10), "The \(name) widget was not installed.")
        let menu = freshInstalledWidgetMenu(for: widget)
        XCTAssertNotNil(menu, "The installed \(name) identity opened no new native widget menu.")
        return menu ?? notificationCenter.menus
            .matching(NSPredicate(format: "identifier == %@", "__missing-installed-menu__"))
            .firstMatch
    }

    @MainActor
    private func freshInstalledWidgetMenu(for widget: XCUIElement) -> XCUIElement? {
        guard closeMenus() else { return nil }
        let baseline = notificationCenter.menus.count
        widget.rightClick()
        guard DemoLaunch.wait(timeout: 3, until: {
            notificationCenter.menus.count == baseline + 1
        }) else {
            _ = closeMenus()
            return nil
        }
        let menus = notificationCenter.menus.allElementsBoundByIndex
        guard menus.count == baseline + 1, let menu = menus.last else {
            _ = closeMenus()
            return nil
        }
        let remove = firstElement(containingAny: ["Remove Widget"], in: menu)
        guard DemoLaunch.wait(for: remove, timeout: 2) else {
            _ = closeMenus()
            return nil
        }
        return menu
    }

    @MainActor
    @discardableResult
    private func closeMenus() -> Bool {
        for _ in 0..<6 where notificationCenter.menus.count > 0 {
            notificationCenter.typeKey(.escape, modifierFlags: [])
        }
        return DemoLaunch.wait(timeout: 2) { notificationCenter.menus.count == 0 }
    }

    @MainActor
    private func installedIdentity(for element: XCUIElement) -> String {
        let frame = element.frame
        let accessibilityIdentity = element.identifier.isEmpty
            ? "\(element.label)|\(String(describing: element.value))"
            : element.identifier
        return [
            "\(element.elementType.rawValue)", accessibilityIdentity,
            String(format: "%.1f", frame.origin.x), String(format: "%.1f", frame.origin.y),
            String(format: "%.1f", frame.width), String(format: "%.1f", frame.height),
        ].joined(separator: "|")
    }

    private func candidateOrder(_ lhs: InstalledCandidate, _ rhs: InstalledCandidate) -> Bool {
        if lhs.area != rhs.area { return lhs.area < rhs.area }
        return lhs.identity < rhs.identity
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
                let widget = installedWidget(named: name, required: false)
                guard widget.exists else { break }
                guard let menu = freshInstalledWidgetMenu(for: widget) else { break }
                let remove = firstElement(containingAny: ["Remove Widget"], in: menu)
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
    private func cleanupInstalledWidgets(
        named names: [String] = ["Metric", "Project Health", "Feature Flag"]
    ) {
        closeTransientSurfaces()
        removeInstalledWidgets(named: names)
        closeTransientSurfaces()
    }

    @MainActor
    private func closeTransientSurfaces() {
        for _ in 0..<6 {
            let hasEditor = notificationCenter.popovers.firstMatch.exists
                || notificationCenter.sheets.firstMatch.exists
                || notificationCenter.menus.firstMatch.exists
            guard hasEditor else { break }
            notificationCenter.typeKey(.escape, modifierFlags: [])
        }
        closeGalleryIfOpen()
    }

    // MARK: - Signed build preflight

    @MainActor
    private func acceptanceLaunchEnvironment(runID: String) -> [String: String] {
        [
            "GETHOG_SIGNED_WIDGET_ACCEPTANCE": "xctest-fixed-fiction-v1",
            "GETHOG_SIGNED_WIDGET_ACCEPTANCE_RUN_ID": runID,
        ]
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
