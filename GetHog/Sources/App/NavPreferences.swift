import Foundation
import SwiftUI

/// Which four product screens the user has put in the phone's tab bar.
///
/// The bar holds five: four product surfaces and Search, which is structurally
/// the fifth because it is the only route to every other screen on a phone. So
/// what is a preference here is the four, and only the four.
///
/// `UserDefaults.standard` rather than the App Group, for the reason
/// `SearchSuggestions` records about its own store: this is one person's
/// arrangement of one app's chrome on one device, and no widget or intent reads
/// it.
///
/// An injected `@Observable` rather than `@AppStorage` in `RootView`, because
/// the editor and the bar have to be one object. Two `@AppStorage` views of one
/// key agree eventually, and an editor whose effect on the bar is not immediate
/// reads as broken.
@MainActor
@Observable
final class NavPreferences {

    /// Four, and not a preference itself. The bar draws five, Search takes the
    /// fifth, and a user-chosen count buys nothing but a bar with holes in it.
    static let slotCount = 4

    private static let defaultsKey = "tabBarTabs"

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var barTabs: [AppTab]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // A verification run's bar, set before any body has read it. Sanitised
        // like anything else, so a typo in the launch environment degrades to
        // the default four rather than to an empty bar.
        if let launched = DebugLaunch.tabBar {
            barTabs = Self.sanitised(launched)
            return
        }
        #endif
        barTabs = Self.sanitised(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// The five the phone's bar draws, in order.
    var alwaysVisible: [AppTab] { barTabs + [.search] }

    /// Everything reached through the index instead, in the order it is listed.
    var indexedScreens: [AppTab] {
        AppTab.groupedScreens(excluding: barTabs).flatMap(\.tabs) + AppTab.utility
    }

    /// Puts `tab` in `slot`, swapping if it already holds one.
    ///
    /// Swapping rather than replacing is what keeps the bar four *distinct*
    /// screens without the editor having to explain itself: choosing Flags for
    /// slot 1 when Flags is in slot 4 moves slot 1's screen to slot 4, which is
    /// what the gesture looks like it should do.
    func assign(_ tab: AppTab, to slot: Int) {
        guard AppTab.productScreens.contains(tab), barTabs.indices.contains(slot) else { return }
        var tabs = barTabs
        if let existing = tabs.firstIndex(of: tab) {
            tabs.swapAt(existing, slot)
        } else {
            tabs[slot] = tab
        }
        write(tabs)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var tabs = barTabs
        tabs.move(fromOffsets: source, toOffset: destination)
        write(tabs)
    }

    func reset() { write(AppTab.primary) }

    private func write(_ tabs: [AppTab]) {
        barTabs = Self.sanitised(tabs.map(\.rawValue))
        defaults.set(barTabs.map(\.rawValue), forKey: Self.defaultsKey)
    }

    /// Turns whatever was stored into exactly four distinct product screens.
    ///
    /// Every clause here is a state a *future* build can be handed by a past
    /// one, which is why none of them is an assertion: a screen can be deleted
    /// between versions, and an app that trapped on its own stored preference
    /// would not launch at all.
    ///
    /// `.search` and `.settings` are refused without being named: neither is in
    /// any section, so `productScreens` does not contain them.
    static func sanitised(_ raw: [String]) -> [AppTab] {
        var result: [AppTab] = []
        for value in raw {
            guard let tab = AppTab(rawValue: value),
                  AppTab.productScreens.contains(tab),
                  !result.contains(tab)
            else { continue }
            result.append(tab)
            if result.count == slotCount { break }
        }
        // Padding is what makes "never empty" true. The defaults are the source
        // because they are the only four guaranteed to exist.
        for tab in AppTab.primary where result.count < slotCount {
            if !result.contains(tab) { result.append(tab) }
        }
        return result
    }
}
