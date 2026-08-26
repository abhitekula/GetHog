import GetHogKit
import SwiftUI

enum MacSettingsWindow {
    static let id = "settings"
}

/// One name per `SettingsRoot` section, so the Mac regrouping below is data a
/// test can check for coverage rather than a layout a screenshot has to.
enum SettingsSectionID: String, CaseIterable, Hashable {
    case account, project, permissions, apiKey
    case navigation
    case usage, sdkHealth, about
}

/// The four panes of the Mac Settings window (spec §2), and which sections
/// each one hosts. Every `SettingsSectionID` must appear exactly once across
/// the four — `MacSettingsRegroupingTests` holds that line.
enum MacSettingsPane: String, CaseIterable, Hashable, Identifiable {
    case account, display, refresh, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: "Account"
        case .display: "Display"
        case .refresh: "Refresh"
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
        case .refresh: [.usage]
        case .advanced: [.sdkHealth, .about]
        }
    }
}

/// The detail screen shown by the Mac Settings window. Its route is
/// state owned by `MacSettingsRoot`, above the dynamic tab content, so leaving
/// a detail cannot make `TabView` infer another pane.
enum MacSettingsDestination: Hashable {
    case about

    var pane: MacSettingsPane {
        switch self {
        case .about: .advanced
        }
    }
}

/// Native Settings panes stay usable in the compact Settings window without
/// letting a resized wide window turn the explanatory footers into long,
/// hard-to-scan lines. The outer scene remains resizable; this only bounds its
/// Form content.
private enum MacSettingsLayout {
    static let maximumFormWidth: CGFloat = 680
}

/// The ⌘, window: the same section views and stores as the iOS Settings
/// screen, in a Mac container. Wired by `GetHogMacApp`'s `Settings` scene.
struct MacSettingsRoot: View {
    @Environment(AppModel.self) private var model
    /// Owned here for the reason SettingsRoot owns them on iOS: results
    /// outlive the rows that trigger the loading.
    @State private var quotaStore = QuotaStore()
    @State private var sdkHealthStore = SDKHealthStore()
    @State private var selectedPane: MacSettingsPane = .account
    @State private var destination: MacSettingsDestination?

    var body: some View {
        // SwiftUI's generated Back control is visibly inert when a native
        // Settings scene pushes across a dynamic TabView. Keep one stack as
        // the title/toolbar host, but switch its root content explicitly and
        // let the authored Back action clear the same state that presents it.
        NavigationStack {
            Group {
                if let destination {
                    detail(destination)
                } else {
                    settingsTabs
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480)
        .task { AppTips.refresh(from: model) }
    }

    private var settingsTabs: some View {
        TabView(selection: $selectedPane) {
            ForEach(MacSettingsPane.allCases) { pane in
                Tab(pane.title, systemImage: pane.systemImage, value: pane) {
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
                    .controlSize(.regular)
                    .frame(maxWidth: MacSettingsLayout.maximumFormWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(_ destination: MacSettingsDestination) -> some View {
        VStack(spacing: 0) {
            MacSettingsDetailHeader(
                pane: destination.pane,
                destination: self.$destination
            )
            Divider()
            Group {
                switch destination {
                case .about:
                    AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func section(for id: SettingsSectionID) -> some View {
        switch id {
        case .account: SettingsAccountSection()
        case .project: SettingsProjectSection()
        case .permissions: SettingsPermissionsSection()
        case .apiKey: SettingsAPIKeySection()
        case .navigation: SettingsNavigationSection()
        case .usage: SettingsUsageSection(quotaStore: quotaStore)
        case .sdkHealth: SettingsSDKHealthSection(store: sdkHealthStore)
        case .about:
            SettingsAboutSection(openAbout: {
                selectedPane = .advanced
                destination = .about
            })
        }
    }
}

/// SwiftUI-generated navigation Back items paint but do not complete this
/// Settings detail dismissal on macOS 26. This header stays in the content
/// hierarchy and writes through the root destination binding directly.
private struct MacSettingsDetailHeader: View {
    let pane: MacSettingsPane
    @Binding var destination: MacSettingsDestination?

    var body: some View {
        HStack {
            Button { destination = nil } label: {
                Label("Back to \(pane.title)", systemImage: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .minimumHitTarget()
            .accessibilityIdentifier("gethog.settings-detail-back")
            .keyboardShortcut("[", modifiers: .command)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

enum MacSidebarSettings {
    static let resetTitle = "Reset Sidebar Sections"

    static func resetValue(from persistedValue: String) -> String {
        var expansion = MacSidebarExpansion(persistedValue: persistedValue)
        expansion.reset()
        return expansion.persistedValue
    }
}

/// Mac-only: reopens the source-list sections that start expanded.
private struct MacSidebarSection: View {
    @AppStorage(MacSidebarExpansion.storageKey)
    private var persistedSidebarExpansion = MacSidebarExpansion.defaultPersistedValue

    var body: some View {
        Section {
            Button(MacSidebarSettings.resetTitle) {
                persistedSidebarExpansion = MacSidebarSettings.resetValue(
                    from: persistedSidebarExpansion
                )
            }
        } footer: {
            Text("Analyze and Monitor reopen. Nothing else changes.")
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
