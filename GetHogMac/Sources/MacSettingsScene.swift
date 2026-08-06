import GetHogKit
import SwiftUI

/// One name per `SettingsRoot` section, so the Mac regrouping below is data a
/// test can check for coverage rather than a layout a screenshot has to.
enum SettingsSectionID: String, CaseIterable, Hashable {
    case account, project, permissions, apiKey
    case navigation, alerts
    case usage, sdkHealth, about
}

/// The four panes of the Mac Settings window (spec §2), and which sections
/// each one hosts. Every `SettingsSectionID` must appear exactly once across
/// the four — `MacSettingsRegroupingTests` holds that line.
enum MacSettingsPane: String, CaseIterable, Identifiable {
    case account, display, refresh, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: "Account"
        case .display: "Display"
        case .refresh: "Refresh & Notifications"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .account: "person.crop.circle"
        case .display: "sidebar.left"
        case .refresh: "arrow.clockwise"
        case .advanced: "gearshape.2"
        }
    }

    var sections: [SettingsSectionID] {
        switch self {
        case .account: [.account, .project, .permissions, .apiKey]
        case .display: [.navigation]
        case .refresh: [.alerts]
        case .advanced: [.usage, .sdkHealth, .about]
        }
    }
}

/// The ⌘, window: the same section views and stores as the iOS Settings
/// screen, in a Mac container. Wired by `GetHogMacApp`'s `Settings` scene.
struct MacSettingsRoot: View {
    @Environment(AppModel.self) private var model
    /// Owned here for the reason SettingsRoot owns them on iOS: results
    /// outlive the rows that trigger the loading.
    @State private var quotaStore = QuotaStore()
    @State private var sdkHealthStore = SDKHealthStore()

    var body: some View {
        TabView {
            ForEach(MacSettingsPane.allCases) { pane in
                Tab(pane.title, systemImage: pane.systemImage) {
                    // A stack, because two of the nine sections are
                    // `NavigationLink`s — Metric alerts and About — and a link
                    // with nothing to push into is an inert row.
                    NavigationStack {
                        Form {
                            ForEach(pane.sections, id: \.self) { id in
                                section(for: id)
                            }
                            if pane == .display {
                                MacSidebarSection()
                                MacMenuBarSection()
                            }
                        }
                        .formStyle(.grouped)
                    }
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480)
        .task { AppTips.refresh(from: model) }
    }

    @ViewBuilder
    private func section(for id: SettingsSectionID) -> some View {
        switch id {
        case .account: SettingsAccountSection()
        case .project: SettingsProjectSection()
        case .permissions: SettingsPermissionsSection()
        case .apiKey: SettingsAPIKeySection()
        case .navigation: SettingsNavigationSection()
        case .alerts: SettingsAlertsSection()
        case .usage: SettingsUsageSection(quotaStore: quotaStore)
        case .sdkHealth: SettingsSDKHealthSection(store: sdkHealthStore)
        case .about: SettingsAboutSection()
        }
    }
}

/// Mac-only: puts the sidebar back the way it started. The sidebar itself has
/// no such affordance — macOS gives a `.sidebarAdaptable` tab view no Edit
/// button, only drag-to-reorder and a per-row hide — and a hidden section is
/// otherwise invisible forever.
private struct MacSidebarSection: View {
    @AppStorage("sidebarCustomization") private var sidebarCustomization = TabViewCustomization()

    var body: some View {
        Section {
            Button("Reset Sidebar Arrangement") {
                sidebarCustomization.resetVisibility()
                sidebarCustomization.resetSectionOrder()
            }
        } footer: {
            Text("Hidden and reordered sidebar items go back to the defaults. Nothing else changes.")
        }
    }
}

/// Mac-only, like the sidebar section above it: the spec §4 ambient-presence
/// switch. The footer states both halves of the contract, because "off quits on
/// close" is behaviour a toggle label alone would hide — and a user who closes
/// the window expecting the app to keep running deserves to have been told.
private struct MacMenuBarSection: View {
    @AppStorage(MacMenuBar.keepOnCloseKey) private var keepOnClose = false

    var body: some View {
        Section {
            Toggle("Keep GetHog in the menu bar when the window is closed", isOn: $keepOnClose)
        } footer: {
            Text(
                "On: closing the last window leaves your headline metric in the menu bar and "
                    + "GetHog keeps running. Off: closing the last window quits GetHog."
            )
        }
    }
}
