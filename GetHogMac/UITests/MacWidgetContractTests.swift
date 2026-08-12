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

    private struct InstalledRawMatch {
        let id: Int
        let element: XCUIElement
        let excludedType: Bool
    }

    private enum InstalledResolution {
        case absent
        case resolved([InstalledCandidate])
        case blocked(String)
    }

    private enum InstalledPreflightResolution {
        case absent
        case probeReady([InstalledRawMatch])
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

    /// Catches a gallery-only implementation: each teamless Debug widget must
    /// install, expose exactly its supported native resize choices, keep its
    /// static configuration free of Edit/Configure actions, tell the truth
    /// about its unshared container, and foreground the host app when opened.
    /// App-Intent editor coverage belongs to the signed Distribution contract.
    @MainActor
    func testInstalledDebugWidgetsResizeDiscloseAndOpenGetHog() {
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

        assertNoConfigurationAction(metricWidget, named: "Metric")
        assertNoConfigurationAction(healthWidget, named: "Project Health")
        assertNoConfigurationAction(flagWidget, named: "Feature Flag")

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
        let expectedFreshness = "Updated just now"
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
    private func assertNoConfigurationAction(
        _ widget: XCUIElement,
        named name: String
    ) {
        let menu = installedWidgetMenu(for: widget, named: name)
        defer {
            XCTAssertTrue(closeMenus(), "The \(name) static-widget menu did not close after inspection.")
        }
        let edit = firstElement(containingAny: ["Edit Widget", "Configure Widget"], in: menu)
        var witness = InstalledWidgetStaticMenuAbsenceWitness(minimumStableDuration: 1)
        var resolution = InstalledWidgetStaticMenuAbsenceResolution.pending
        _ = DemoLaunch.wait(timeout: 2.5) {
            resolution = witness.observe(
                InstalledWidgetStaticMenuSample(
                    menuVisible: menu.exists && menu.isHittable,
                    removeActionVisible: self.firstHittableElement(
                        containingAny: ["Remove Widget"],
                        in: menu
                    ) != nil,
                    configurationActionVisible: edit.exists
                ),
                at: ProcessInfo.processInfo.systemUptime
            )
            return resolution != .pending
        }
        switch resolution {
        case .witnessed:
            break
        case .blocked(.configurationActionVisible):
            XCTFail(
                "The teamless Debug \(name) widget exposed Edit/Configure despite its static configuration."
            )
        case .pending:
            XCTFail(
                "The \(name) menu and its Remove Widget action did not remain stable long enough to prove configuration absent."
            )
        }
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
        let preflight = installedWidgetPreflight(named: name)
        let rawMatches: [InstalledRawMatch]
        switch preflight {
        case .absent:
            return .absent
        case let .blocked(reason):
            return .blocked(reason)
        case let .probeReady(matches):
            rawMatches = matches
        }

        for rawMatch in rawMatches {
            switch waitForProbeReady(
                [rawMatch],
                timeout: 2,
                context: "candidate \(rawMatch.id) before menu witnessing"
            ) {
            case .absent:
                return .blocked("candidate \(rawMatch.id) lost its authored-match identity")
            case let .blocked(reason):
                return .blocked(reason)
            case .probeReady:
                break
            }

            switch witnessesInstalledWidgetMenu(for: rawMatch.element) {
            case .witnessed:
                break
            case let .blocked(reason):
                return .blocked("candidate \(rawMatch.id) menu probe failed: \(reason)")
            }

            switch waitForProbeReady(
                [rawMatch],
                timeout: 2,
                context: "candidate \(rawMatch.id) after menu witnessing"
            ) {
            case .absent:
                return .blocked("candidate \(rawMatch.id) became stale during menu witnessing")
            case let .blocked(reason):
                return .blocked(reason)
            case .probeReady:
                break
            }
        }

        let finalMatches: [InstalledRawMatch]
        switch waitForProbeReady(
            rawMatches,
            timeout: 2,
            context: "menu-witnessed candidates before geometry resolution"
        ) {
        case .absent:
            return .blocked("menu-witnessed candidates lost their authored-match identities")
        case let .blocked(reason):
            return .blocked(reason)
        case let .probeReady(matches):
            finalMatches = matches
        }

        var witnessed: [InstalledCandidate] = []
        for rawMatch in finalMatches {
            let frame = rawMatch.element.frame
            guard rawMatch.element.exists,
                  rawMatch.element.isHittable,
                  InstalledWidgetFrameValidity(frame: frame) == .valid else {
                return .blocked("candidate \(rawMatch.id) became stale while binding witnessed geometry")
            }
            witnessed.append(InstalledCandidate(
                id: rawMatch.id,
                element: rawMatch.element,
                frame: frame
            ))
        }

        let geometry = InstalledWidgetGeometryResolver.resolve(witnessed.map {
            InstalledWidgetGeometryCandidate(id: $0.id, frame: $0.frame)
        })
        switch geometry {
        case .absent:
            return .blocked("geometry returned absent after authored candidates were witnessed")
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
    private func installedWidgetPreflight(named name: String) -> InstalledPreflightResolution {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            name,
            name
        )
        let excludedTypes: Set<XCUIElement.ElementType> = [
            .application, .window, .sheet, .popover, .scrollView,
            .searchField, .menu, .menuItem,
        ]
        let initial = rawInstalledWidgetMatches(
            matching: predicate,
            excluding: excludedTypes
        )

        switch classifyPreflight(initial) {
        case .absent:
            return waitForSettledAbsence(
                matching: predicate,
                excluding: excludedTypes
            )
        case .probeReady, .blocked:
            return waitForProbeReady(
                initial,
                timeout: 2,
                context: "raw name-matched accessibility candidates",
                allowHittableSettling: true
            )
        }
    }

    @MainActor
    private func waitForSettledAbsence(
        matching predicate: NSPredicate,
        excluding excludedTypes: Set<XCUIElement.ElementType>
    ) -> InstalledPreflightResolution {
        var previous: [InstalledWidgetPreflightMatch]?
        var stableSamples = 0
        var nonAbsentMatches: [InstalledRawMatch]?
        let settled = DemoLaunch.wait(timeout: 2) {
            let rawMatches = self.rawInstalledWidgetMatches(
                matching: predicate,
                excluding: excludedTypes
            )
            let snapshots = rawMatches.map(self.preflightSnapshot)
            guard InstalledWidgetPreflightClassifier.classify(snapshots) == .absent else {
                nonAbsentMatches = rawMatches
                return true
            }
            guard self.installedWidgetSystemUIIsSettled() else {
                previous = nil
                stableSamples = 0
                return false
            }

            if snapshots == previous {
                stableSamples += 1
            } else {
                previous = snapshots
                stableSamples = 1
            }
            return stableSamples >= 3
        }

        if let nonAbsentMatches {
            return waitForProbeReady(
                nonAbsentMatches,
                timeout: 2,
                context: "candidate observed while settling an empty authored query",
                allowHittableSettling: true
            )
        }
        guard settled else {
            return .blocked("system UI did not settle before authored-widget absence was verified")
        }
        return .absent
    }

    @MainActor
    private func waitForProbeReady(
        _ rawMatches: [InstalledRawMatch],
        timeout: TimeInterval,
        context: String,
        allowHittableSettling: Bool = false
    ) -> InstalledPreflightResolution {
        var resolution = classifyPreflight(rawMatches)
        if allowHittableSettling,
           case let .blocked(block) = resolution,
           case .notHittable = block {
            let settled = DemoLaunch.wait(timeout: timeout) {
                resolution = self.classifyPreflight(rawMatches)
                switch resolution {
                case .probeReady, .absent:
                    return true
                case let .blocked(currentBlock):
                    if case .notHittable = currentBlock { return false }
                    return true
                }
            }
            if !settled,
               case let .blocked(currentBlock) = resolution,
               case .notHittable = currentBlock {
                return .blocked(
                    "\(context) did not become probe-ready before timeout: \(currentBlock)"
                )
            }
        }

        switch resolution {
        case .absent:
            return .absent
        case let .blocked(block):
            return .blocked("\(context) was blocked: \(block)")
        case let .probeReady(candidateIDs):
            let byID = Dictionary(uniqueKeysWithValues: rawMatches.map { ($0.id, $0) })
            let matches = candidateIDs.compactMap { byID[$0] }
            guard matches.count == candidateIDs.count else {
                return .blocked("\(context) could not bind every probe-ready AX handle")
            }
            return .probeReady(matches)
        }
    }

    @MainActor
    private func classifyPreflight(
        _ rawMatches: [InstalledRawMatch]
    ) -> InstalledWidgetPreflightResolution {
        InstalledWidgetPreflightClassifier.classify(
            rawMatches.map(preflightSnapshot)
        )
    }

    @MainActor
    private func preflightSnapshot(
        _ rawMatch: InstalledRawMatch
    ) -> InstalledWidgetPreflightMatch {
        let exists = rawMatch.element.exists
        let frameValidity = exists
            ? InstalledWidgetFrameValidity(frame: rawMatch.element.frame)
            : .invalid
        return InstalledWidgetPreflightMatch(
            id: rawMatch.id,
            excludedType: rawMatch.excludedType,
            exists: exists,
            hittable: exists && rawMatch.element.isHittable,
            frameValidity: frameValidity
        )
    }

    @MainActor
    private func rawInstalledWidgetMatches(
        matching predicate: NSPredicate,
        excluding excludedTypes: Set<XCUIElement.ElementType>
    ) -> [InstalledRawMatch] {
        // Bind every raw match to its accessibility object before deciding
        // whether it is authored or probe-ready. Index-bound proxies can
        // retarget while Notification Center lays out or removes a widget.
        notificationCenter.descendants(matching: .any)
            .matching(predicate)
            .allElementsBoundByAccessibilityElement
            .enumerated()
            .map { id, element in
                InstalledRawMatch(
                    id: id,
                    element: element,
                    excludedType: excludedTypes.contains(element.elementType)
                )
            }
    }

    @MainActor
    private func installedWidgetSystemUIIsSettled() -> Bool {
        let hasVisibleMenu = notificationCenter.menus.allElementsBoundByIndex.contains {
            $0.exists && $0.isHittable
        }
        return !hasVisibleMenu
            && hittableRemoveWidget() == nil
            && !notificationCenter.popovers.firstMatch.exists
            && !notificationCenter.sheets.firstMatch.exists
            && !notificationCenter.searchFields.firstMatch.exists
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
