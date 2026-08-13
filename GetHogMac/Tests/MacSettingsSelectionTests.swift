import Foundation
import Testing
@testable import GetHog

@Suite("Mac settings navigation")
struct MacSettingsSelectionTests {

    @Test("Metric alerts belongs to Refresh")
    func metricAlertsBelongsToRefresh() {
        #expect(MacSettingsDestination.metricAlerts.pane == .refresh)
    }

    @Test("About belongs to Advanced")
    func aboutBelongsToAdvanced() {
        #expect(MacSettingsDestination.about.pane == .advanced)
    }

    /// A dedicated `Window` owns Settings because SwiftUI's native `Settings`
    /// scene continuously fixes its AppKit window to its content size on
    /// macOS 26. Every entry point must address the same single-instance id.
    @Test("Settings uses one resizable owned window")
    func settingsUsesOneResizableOwnedWindow() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repository.appendingPathComponent(
                "GetHogMac/Sources/GetHogMacApp.swift"
            ),
            encoding: .utf8
        )
        let commandsSource = try String(
            contentsOf: repository.appendingPathComponent(
                "GetHogMac/Sources/MacCommands.swift"
            ),
            encoding: .utf8
        )
        let rootSource = try String(
            contentsOf: repository.appendingPathComponent(
                "GetHogMac/Sources/MacRootView.swift"
            ),
            encoding: .utf8
        )
        let menuBarSource = try String(
            contentsOf: repository.appendingPathComponent(
                "GetHogMac/Sources/MacMenuBarExtra.swift"
            ),
            encoding: .utf8
        )
        let macSource = try String(
            contentsOf: repository.appendingPathComponent(
                "GetHogMac/Sources/MacSettingsScene.swift"
            ),
            encoding: .utf8
        )

        #expect(macSource.contains("enum MacSettingsWindow"))
        #expect(macSource.contains("static let id = \"settings\""))
        #expect(!macSource.contains("MacSettingsWindowConfigurator"))
        #expect(appSource.contains("Window(\"Settings\", id: MacSettingsWindow.id)"))
        #expect(appSource.contains(".defaultSize(width: 900, height: 568)"))
        #expect(appSource.contains(".windowResizability(.contentMinSize)"))
        #expect(!appSource.contains("Settings {"))
        #expect(commandsSource.contains("@Environment(\\.openWindow)"))
        #expect(commandsSource.contains("CommandGroup(replacing: .appSettings)"))
        #expect(commandsSource.contains("Button(\"Settings…\")"))
        #expect(commandsSource.contains(".keyboardShortcut(\",\", modifiers: .command)"))
        #expect(commandsSource.contains("openWindow(id: MacSettingsWindow.id)"))
        #expect(rootSource.contains("@Environment(\\.openWindow)"))
        #expect(rootSource.contains("openWindow(id: MacSettingsWindow.id)"))
        #expect(menuBarSource.contains("openWindow(id: MacSettingsWindow.id)"))
        #expect(!rootSource.contains("@Environment(\\.openSettings)"))
        #expect(!menuBarSource.contains("@Environment(\\.openSettings)"))
    }

    /// The Mac owns these two details above the dynamic `TabView`. The shared
    /// sections keep their ordinary `NavigationLink` fallback for every other
    /// shell, while the Mac supplies actions into its single navigation slot.
    @Test("Mac root owns nested Settings destinations")
    func macRootOwnsNestedSettingsDestinations() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macSource = try String(
            contentsOf: repository.appendingPathComponent(
                "GetHogMac/Sources/MacSettingsScene.swift"
            ),
            encoding: .utf8
        )
        let sharedSource = try String(
            contentsOf: repository.appendingPathComponent(
                "GetHog/Sources/Settings/SettingsRoot.swift"
            ),
            encoding: .utf8
        )

        #expect(macSource.contains("enum MacSettingsDestination: Hashable"))
        #expect(macSource.contains("@State private var selectedPane: MacSettingsPane = .account"))
        #expect(macSource.contains("@State private var destination: MacSettingsDestination?"))
        #expect(macSource.contains("TabView(selection: $selectedPane)"))
        #expect(macSource.contains("if let destination"))
        #expect(macSource.contains("detail(destination)"))
        #expect(macSource.contains("MacSettingsDetailHeader("))
        #expect(macSource.contains("destination: self.$destination"))
        #expect(macSource.contains("@Binding var destination: MacSettingsDestination?"))
        #expect(macSource.contains("Label(\"Back to \\(pane.title)\", systemImage: \"chevron.backward\")"))
        #expect(macSource.contains(".accessibilityIdentifier(\"gethog.settings-detail-back\")"))
        #expect(macSource.contains("Button { destination = nil }"))
        #expect(macSource.contains(".keyboardShortcut(\"[\", modifiers: .command)"))
        #expect(!macSource.contains(".onExitCommand"))
        #expect(!macSource.contains("ToolbarItem(placement: .navigation)"))
        #expect(!macSource.contains(".navigationDestination(item:"))
        #expect(macSource.components(separatedBy: "NavigationStack {").count - 1 == 1)
        #expect(macSource.contains("openMetricAlerts:"))
        #expect(macSource.contains("selectedPane = .refresh"))
        #expect(macSource.contains("destination = .metricAlerts"))
        #expect(macSource.contains("openAbout:"))
        #expect(macSource.contains("selectedPane = .advanced"))
        #expect(macSource.contains("destination = .about"))
        #expect(!macSource.contains("MacSettingsNavigationState"))

        #expect(sharedSource.contains("var openMetricAlerts: (() -> Void)?"))
        #expect(sharedSource.contains("if let openMetricAlerts"))
        #expect(sharedSource.contains("Button(action: openMetricAlerts)"))
        #expect(sharedSource.contains("MetricAlertsView(snapshotStore: snapshotStore)"))
        #expect(sharedSource.contains("var openAbout: (() -> Void)?"))
        #expect(sharedSource.contains("if let openAbout"))
        #expect(sharedSource.contains("Button(action: openAbout)"))
        #expect(sharedSource.contains("AboutView()"))
    }
}
