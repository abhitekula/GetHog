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
        let id: Int
        let element: XCUIElement
        let frame: CGRect
    }

    private enum InstalledResolution {
        case absent
        case resolved([InstalledCandidate])
        case blocked(String)
    }

    private enum MenuProbeResolution {
        case opened(XCUIElement)
        case blocked(String)
    }

    private enum MenuWitnessResolution {
        case witnessed
        case blocked(String)
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

        let metricWidget = installedWidget(named: "Metric")
        let healthWidget = installedWidget(named: "Project Health")
        let flagWidget = installedWidget(named: "Feature Flag")

        assertResizeFamilies(
            metricWidget,
            named: "Metric",
            expected: ["Small", "Medium", "Large"]
        )
        assertResizeFamilies(
            healthWidget,
            named: "Project Health",
            expected: ["Small", "Medium", "Large"]
        )
        assertResizeFamilies(
            flagWidget,
            named: "Feature Flag",
            expected: ["Small", "Medium"]
        )

        assertConfiguration(metricWidget, named: "Metric", parameter: "Metric")
        assertConfiguration(flagWidget, named: "Feature Flag", parameter: "Feature Flag")

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
    private func assertResizeFamilies(
        _ widget: XCUIElement,
        named name: String,
        expected: [String]
    ) {
        let nativeSizes = ["Small", "Medium", "Large", "Extra Large"]
        let initialMenu = installedWidgetMenu(for: widget, named: name)
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
            let menu = installedWidgetMenu(for: widget, named: name)
            let size = menu.menuItems[family]
            XCTAssertTrue(
                DemoLaunch.wait(for: size, timeout: 5),
                "The installed \(name) widget offered no native \(family) resize."
            )
            size.click()
        }

    }

    @MainActor
    private func assertConfiguration(
        _ widget: XCUIElement,
        named name: String,
        parameter: String
    ) {
        let menu = installedWidgetMenu(for: widget, named: name)
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
    private func installedWidget(named name: String) -> XCUIElement {
        switch installedWidgetResolution(named: name) {
        case .absent:
            XCTFail("No installed \(name) widget was present.")
            return missingInstalledWidget(named: name)
        case let .blocked(reason):
            XCTFail("Installed \(name) widget resolution was blocked: \(reason).")
            return missingInstalledWidget(named: name)
        case let .resolved(canonicals):
            guard canonicals.count == 1, let canonical = canonicals.first else {
                XCTFail("Expected exactly one installed \(name) widget cluster; found \(canonicals.count).")
                return missingInstalledWidget(named: name)
            }
            return canonical.element
        }
    }

    @MainActor
    private func installedWidgetResolution(named name: String) -> InstalledResolution {
        guard closeMenus() else {
            return .blocked("could not close pre-existing menus")
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
        // Bind each proxy to the witnessed accessibility object itself. An
        // index-bound query can silently retarget after a resize reorders the
        // tree, defeating the promise that later actions reuse this widget.
        let elements = notificationCenter.descendants(matching: .any)
            .matching(predicate).allElementsBoundByAccessibilityElement
        var witnessed: [InstalledCandidate] = []

        for (id, element) in elements.enumerated()
        where element.exists && element.isHittable && !excludedTypes.contains(element.elementType) {
            let frame = element.frame
            let candidate = InstalledCandidate(
                id: id,
                element: element,
                frame: frame
            )
            switch witnessesInstalledWidgetMenu(for: element) {
            case .witnessed:
                witnessed.append(candidate)
            case let .blocked(reason):
                return .blocked("candidate \(id) menu probe failed: \(reason)")
            }
        }

        let geometry = InstalledWidgetGeometryResolver.resolve(witnessed.map {
            InstalledWidgetGeometryCandidate(id: $0.id, frame: $0.frame)
        })
        switch geometry {
        case .absent:
            return .absent
        case let .blocked(reason):
            return .blocked(reason.description)
        case let .resolved(clusters):
            let byID = Dictionary(uniqueKeysWithValues: witnessed.map { ($0.id, $0) })
            var canonicals: [InstalledCandidate] = []
            for cluster in clusters {
                guard let canonical = byID[cluster.canonicalID] else {
                    return .blocked("could not bind canonical AX handle \(cluster.canonicalID)")
                }
                canonicals.append(canonical)
            }
            return .resolved(canonicals)
        }
    }

    @MainActor
    private func missingInstalledWidget(named name: String) -> XCUIElement {
        firstElement(
            containingAny: ["__missing-installed-widget-\(name)__"],
            in: notificationCenter
        )
    }

    @MainActor
    private func installedWidgetMenu(for widget: XCUIElement, named name: String) -> XCUIElement {
        XCTAssertTrue(DemoLaunch.wait(for: widget, timeout: 10), "The \(name) widget was not installed.")
        switch openInstalledWidgetMenu(for: widget) {
        case let .opened(menu):
            return menu
        case let .blocked(reason):
            XCTFail("The installed \(name) menu was blocked: \(reason).")
            return notificationCenter.menus
                .matching(NSPredicate(format: "identifier == %@", "__missing-installed-menu__"))
                .firstMatch
        }
    }

    @MainActor
    private func witnessesInstalledWidgetMenu(for widget: XCUIElement) -> MenuWitnessResolution {
        switch openInstalledWidgetMenu(for: widget) {
        case let .blocked(reason):
            return .blocked(reason)
        case .opened:
            guard closeMenus() else {
                return .blocked("could not close the witnessed widget menu")
            }
            return .witnessed
        }
    }

    @MainActor
    private func openInstalledWidgetMenu(for widget: XCUIElement) -> MenuProbeResolution {
        guard closeMenus() else { return .blocked("could not close pre-existing menus") }
        guard hittableRemoveWidget() == nil else {
            return .blocked("a hittable Remove Widget action survived menu closure")
        }
        guard widget.exists && widget.isHittable else {
            return .blocked("the AX handle no longer exists or is not hittable")
        }
        widget.rightClick()
        guard DemoLaunch.wait(timeout: 3, until: {
            visibleInstalledWidgetMenu() != nil
        }) else {
            _ = closeMenus()
            return .blocked("right-click exposed no visible menu with scoped Remove Widget")
        }
        guard let menu = visibleInstalledWidgetMenu() else {
            _ = closeMenus()
            return .blocked("the witnessed menu disappeared before its AX handle was bound")
        }
        return .opened(menu)
    }

    @MainActor
    private func visibleInstalledWidgetMenu() -> XCUIElement? {
        notificationCenter.menus.allElementsBoundByIndex.first { menu in
            menu.exists
                && menu.isHittable
                && firstHittableElement(containingAny: ["Remove Widget"], in: menu) != nil
        }
    }

    @MainActor
    private func hittableRemoveWidget() -> XCUIElement? {
        firstHittableElement(containingAny: ["Remove Widget"], in: notificationCenter)
    }

    @MainActor
    @discardableResult
    private func closeMenus() -> Bool {
        for _ in 0..<6 {
            let visibleMenuExists = notificationCenter.menus.allElementsBoundByIndex.contains {
                $0.exists && $0.isHittable
            }
            guard visibleMenuExists || hittableRemoveWidget() != nil else { break }
            notificationCenter.typeKey(.escape, modifierFlags: [])
        }
        return DemoLaunch.wait(timeout: 2) {
            !notificationCenter.menus.allElementsBoundByIndex.contains {
                $0.exists && $0.isHittable
            } && hittableRemoveWidget() == nil
        }
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
        nameLoop: for name in names {
            while true {
                let widget: InstalledCandidate
                switch installedWidgetResolution(named: name) {
                case .absent:
                    continue nameLoop
                case let .blocked(reason):
                    XCTFail("Cleanup of \(name) was blocked: \(reason).")
                    return
                case let .resolved(canonicals):
                    guard let first = canonicals.first else {
                        XCTFail("Cleanup resolved \(name) without a canonical widget.")
                        return
                    }
                    widget = first
                }
                let menu: XCUIElement
                switch openInstalledWidgetMenu(for: widget.element) {
                case let .opened(openedMenu):
                    menu = openedMenu
                case let .blocked(reason):
                    XCTFail("Cleanup could not reopen the canonical \(name) widget menu: \(reason).")
                    return
                }
                guard let remove = firstHittableElement(
                    containingAny: ["Remove Widget"],
                    in: menu
                ) else {
                    _ = closeMenus()
                    XCTFail("Cleanup's canonical \(name) widget menu had no hittable Remove Widget action.")
                    return
                }
                remove.click()
                let confirm = firstElement(containingAny: ["Remove"], in: notificationCenter)
                if DemoLaunch.wait(for: confirm, timeout: 2), confirm.isHittable { confirm.click() }
                guard DemoLaunch.wait(timeout: 10, until: { !widget.element.exists }) else {
                    XCTFail("Cleanup did not remove the selected canonical \(name) widget.")
                    return
                }
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
                || notificationCenter.menus.allElementsBoundByIndex.contains {
                    $0.exists && $0.isHittable
                }
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

    @MainActor
    private func firstHittableElement(
        containingAny values: [String],
        in container: XCUIElement
    ) -> XCUIElement? {
        let predicates = values.map {
            "label CONTAINS[c] '\($0.replacingOccurrences(of: "'", with: "''"))' "
                + "OR value CONTAINS[c] '\($0.replacingOccurrences(of: "'", with: "''"))'"
        }
        return container.descendants(matching: .any)
            .matching(NSPredicate(format: predicates.map { "(\($0))" }.joined(separator: " OR ")))
            .allElementsBoundByIndex
            .first { $0.exists && $0.isHittable }
    }
}
