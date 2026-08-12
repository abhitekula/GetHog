import Foundation
import Testing

@Suite("Mac shared snapshot policy")
struct MacSharedSnapshotPolicyTests {

    @Test("teamless Debug never resolves the App Group container")
    func teamlessDebugUsesPrivateSnapshotStore() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GetHogMac
            .deletingLastPathComponent()  // repository
        let project = try source("project.yml", repository: repository)
        let target = try slice(
            project,
            after: "  GetHogMac:\n",
            before: "\n  # The Mac desktop widgets:"
        )
        let configs = try suffix(target, after: "      configs:\n")
        let debugSettings = try slice(configs, after: "        Debug:\n", before: "        Release:\n")
        let releaseSettings = try suffix(configs, after: "        Release:\n")

        #expect(debugSettings.contains("GetHogMac/Support/GetHogMac.entitlements"))
        #expect(debugSettings.contains(
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS: \"DEBUG GETHOG_UNSHARED_MAC_APP\""
        ))
        #expect(releaseSettings.contains("GetHogMac/Support/GetHogMac-Distribution.entitlements"))
        #expect(!releaseSettings.contains("GETHOG_UNSHARED_MAC_APP"))
        #expect(!releaseSettings.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS"))
        #expect(project.components(separatedBy: "GETHOG_UNSHARED_MAC_APP").count - 1 == 1)

        let generatedProject = try source(
            "GetHog.xcodeproj/project.pbxproj",
            repository: repository
        )
        let generatedCondition =
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG GETHOG_UNSHARED_MAC_APP\";"
        #expect(generatedProject.components(separatedBy: generatedCondition).count - 1 == 1)
        #expect(!generatedProject.contains(
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"$(inherited) GETHOG_UNSHARED_MAC_APP\";"
        ))

        let rawDebugEntitlements = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: repository.appending(path: "GetHogMac/Support/GetHogMac.entitlements")),
            format: nil
        )
        let debugEntitlements = try #require(rawDebugEntitlements as? [String: Any])
        #expect(debugEntitlements["com.apple.security.application-groups"] == nil)

        let policy = try source(
            "GetHogMac/Sources/MacSharedSnapshotPolicy.swift",
            repository: repository
        )
        let guarded = try slice(policy, after: "#if GETHOG_UNSHARED_MAC_APP", before: "#endif")
        let elseRange = try #require(guarded.range(of: "#else"))
        let debugPolicy = guarded[..<elseRange.lowerBound]
        let releasePolicy = guarded[elseRange.upperBound...]
        #expect(debugPolicy.contains("SharedSnapshotStore.resolve"))
        #expect(debugPolicy.contains("container: { _ in nil }"))
        #expect(!debugPolicy.contains(".shared"))
        #expect(releasePolicy.contains("SharedSnapshotStore.shared"))

        #expect(policy.contains("static var sharedDefaults: UserDefaults?"))
        #expect(!policy.contains("static let sharedDefaults: UserDefaults?"))
        let defaultsGuard = try suffix(policy, after: "static var sharedDefaults: UserDefaults?")
        let defaultsDebug = try slice(
            defaultsGuard,
            after: "#if GETHOG_UNSHARED_MAC_APP",
            before: "#else"
        )
        let defaultsRelease = try slice(defaultsGuard, after: "#else", before: "#endif")
        #expect(defaultsDebug.contains("nil"))
        #expect(!defaultsDebug.contains("UserDefaults(suiteName:"))
        #expect(defaultsRelease.contains("UserDefaults(suiteName:"))

        let app = try source("GetHogMac/Sources/GetHogMacApp.swift", repository: repository)
        let factory = try slice(app, after: "enum MacAppModelFactory {", before: "\n}\n#endif")
        #expect(factory.contains("snapshotStore: SharedSnapshotStore = MacSharedSnapshotPolicy.store"))
        #expect(factory.components(separatedBy: "snapshotStore: snapshotStore").count - 1 == 4)
        #expect(app.contains("MacMenuBarController(store: MacSharedSnapshotPolicy.store)"))
        #expect(app.components(separatedBy: "MacRootView(snapshotStore: MacSharedSnapshotPolicy.store)").count - 1 == 2)
        #expect(app.contains("AppModel(snapshotStore: MacSharedSnapshotPolicy.store)"))

        let menuBar = try source("GetHogMac/Sources/MacMenuBarExtra.swift", repository: repository)
        let menuBarInitializer = try slice(
            menuBar,
            after: "init(\n        store: SharedSnapshotStore",
            before: "    ) {"
        )
        #expect(!menuBarInitializer.contains("= .shared"))

        let root = try source("GetHogMac/Sources/MacRootView.swift", repository: repository)
        #expect(root.contains("let snapshotStore: SharedSnapshotStore"))
        #expect(root.contains("snapshotStore.pendingOpen()"))
        #expect(root.contains("snapshotStore.clearPendingOpen()"))
        #expect(root.contains("snapshotStore.loadOrNil()"))
        #expect(!root.contains("SharedSnapshotStore.shared"))

        let settings = try source("GetHogMac/Sources/MacSettingsScene.swift", repository: repository)
        #expect(settings.contains("SettingsAlertsSection(snapshotStore: MacSharedSnapshotPolicy.store)"))

        let intents = try source(
            "GetHog/Sources/Intents/IntentDependencies.swift",
            repository: repository
        )
        let sharedDefaults = try slice(
            intents,
            after: "static var sharedDefaults: UserDefaults? {",
            before: "\n    }"
        )
        #expect(sharedDefaults.contains("#if os(macOS)"))
        #expect(sharedDefaults.contains("MacSharedSnapshotPolicy.sharedDefaults"))
        #expect(sharedDefaults.contains("#else"))
        #expect(sharedDefaults.contains("UserDefaults(suiteName: appGroupID)"))

        let sharedSettings = try source("GetHog/Sources/Settings/SettingsRoot.swift", repository: repository)
        let settingsRoot = try slice(
            sharedSettings,
            after: "struct SettingsRoot: View {",
            before: "\n}\n\n// MARK: - Account"
        )
        #expect(settingsRoot.contains("SettingsAlertsSection(snapshotStore: alertsSnapshotStore)"))
        #expect(settingsRoot.contains("#if os(macOS)"))
        #expect(settingsRoot.contains("MacSharedSnapshotPolicy.store"))
        #expect(settingsRoot.contains("#else"))
        #expect(settingsRoot.contains("SharedSnapshotStore.shared"))
        let alertsSection = try suffix(sharedSettings, after: "struct SettingsAlertsSection: View {")
        #expect(alertsSection.contains("let snapshotStore: SharedSnapshotStore"))
        #expect(!alertsSection.contains("init(snapshotStore: SharedSnapshotStore = .shared)"))
        #expect(alertsSection.contains("MetricAlertsView(snapshotStore: snapshotStore)"))

        let alertsView = try source("GetHog/Sources/Alerts/MetricAlertsView.swift", repository: repository)
        #expect(alertsView.contains("init(snapshotStore: SharedSnapshotStore)"))
        #expect(!alertsView.contains("init(snapshotStore: SharedSnapshotStore = .shared)"))
        #expect(alertsView.contains("MetricWatchController(store: snapshotStore)"))

        let model = try source("GetHog/Sources/App/AppModel.swift", repository: repository)
        #expect(model.contains("MetricAlertDelivery.evaluate(snapshot: snapshot, store: snapshotStore)"))
        let delivery = try source(
            "GetHog/Sources/Alerts/MetricWatchController.swift",
            repository: repository
        )
        let evaluate = try slice(
            delivery,
            after: "static func evaluate(",
            before: ") async {"
        )
        #expect(evaluate.contains("store: SharedSnapshotStore"))
        #expect(!evaluate.contains("= .shared"))
        let controllerInitializer = try slice(
            delivery,
            after: "init(store: SharedSnapshotStore",
            before: ") {"
        )
        #expect(!controllerInitializer.contains("= .shared"))

        let widgetBundle = try source(
            "GetHogMacWidgets/Sources/GetHogMacWidgetBundle.swift",
            repository: repository
        )
        let widgetDefinitions = try slice(
            widgetBundle,
            after: "#if GETHOG_UNSHARED_MAC_WIDGETS",
            before: "#endif"
        )
        #expect(widgetDefinitions.contains("private struct MacDebugHealthWidget: Widget"))
        #expect(widgetDefinitions.contains("app.gethog.widget.debug.health-unshared"))
        #expect(!widgetDefinitions.contains("WidgetCache."))
        let bundle = try suffix(widgetBundle, after: "struct GetHogMacWidgetBundle: WidgetBundle")
        let unsharedBranch = try slice(bundle, after: "#if GETHOG_UNSHARED_MAC_WIDGETS", before: "#else")
        let unsharedRegistrations = unsharedBranch
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix("Widget()") }
        #expect(unsharedRegistrations == [
            "MacDebugMetricWidget()",
            "MacDebugHealthWidget()",
            "MacDebugFlagWidget()",
        ])
        #expect(!unsharedRegistrations.contains("MetricWidget()"))
        #expect(!unsharedRegistrations.contains("HealthWidget()"))
        #expect(!unsharedRegistrations.contains("FlagWidget()"))

        let widgetCache = try source("GetHogWidgets/WidgetCache.swift", repository: repository)
        let widgetStore = try slice(
            widgetCache,
            after: "static var store: SharedSnapshotStore {",
            before: "\n    }"
        )
        #expect(widgetStore.contains("#if os(macOS) && GETHOG_UNSHARED_MAC_WIDGETS"))
        #expect(widgetStore.contains("SharedSnapshotStore.resolve(container: { _ in nil })"))
        #expect(widgetStore.contains("#else"))
        #expect(widgetStore.contains("SharedSnapshotStore.shared"))
    }

    private func source(_ path: String, repository: URL) throws -> String {
        try String(contentsOf: repository.appending(path: path), encoding: .utf8)
    }

    private func slice(
        _ source: some StringProtocol,
        after start: String,
        before end: String
    ) throws -> Substring {
        let concrete = String(source)
        let startRange = try #require(concrete.range(of: start))
        let remainder = concrete[startRange.upperBound...]
        let endRange = try #require(remainder.range(of: end))
        return remainder[..<endRange.lowerBound]
    }

    private func suffix(
        _ source: some StringProtocol,
        after start: String
    ) throws -> Substring {
        let concrete = String(source)
        let startRange = try #require(concrete.range(of: start))
        return concrete[startRange.upperBound...]
    }
}
