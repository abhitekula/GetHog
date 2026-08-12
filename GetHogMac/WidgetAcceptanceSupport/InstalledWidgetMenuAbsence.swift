import Foundation

struct InstalledWidgetStaticMenuSample: Equatable {
    let menuVisible: Bool
    let removeActionVisible: Bool
    let configurationActionVisible: Bool
}

enum InstalledWidgetStaticMenuAbsenceBlock: Equatable {
    case configurationActionVisible
}

enum InstalledWidgetStaticMenuAbsenceResolution: Equatable {
    case pending
    case witnessed
    case blocked(InstalledWidgetStaticMenuAbsenceBlock)
}

/// Requires one continuous interval in which the installed-widget menu and its
/// scoped Remove Widget action remain visible. A late Edit/Configure action
/// blocks immediately instead of allowing an early negative query to pass.
struct InstalledWidgetStaticMenuAbsenceWitness {
    let minimumStableDuration: TimeInterval

    private var stableSince: TimeInterval?

    init(minimumStableDuration: TimeInterval) {
        self.minimumStableDuration = minimumStableDuration
    }

    mutating func observe(
        _ sample: InstalledWidgetStaticMenuSample,
        at timestamp: TimeInterval
    ) -> InstalledWidgetStaticMenuAbsenceResolution {
        if sample.configurationActionVisible {
            return .blocked(.configurationActionVisible)
        }
        guard sample.menuVisible, sample.removeActionVisible else {
            stableSince = nil
            return .pending
        }
        guard let stableSince else {
            self.stableSince = timestamp
            return minimumStableDuration == 0 ? .witnessed : .pending
        }
        return timestamp - stableSince >= minimumStableDuration
            ? .witnessed
            : .pending
    }
}
