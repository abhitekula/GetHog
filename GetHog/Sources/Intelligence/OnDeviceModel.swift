import Foundation
import FoundationModels

/// Whether Apple's on-device model can run here — and when it cannot, which of
/// several unrelated reasons that is.
///
/// **Why this is an app-level type rather than a passthrough of Apple's enum.**
/// `SystemLanguageModel.Availability.UnavailableReason` is not `@frozen`, so a
/// `switch` over it must carry `@unknown default` somewhere; doing that once,
/// here, keeps every call site total. It also lets the *copy* live next to the
/// case it explains, which matters because the three unavailable reasons are not
/// shades of the same thing:
///
/// * `deviceNotEligible` is permanent for this hardware. Nothing the reader does
///   changes it, so the copy must not suggest an action.
/// * `appleIntelligenceNotEnabled` is one Settings toggle away, and saying so is
///   the difference between a dead feature and a feature the reader can turn on.
/// * `modelNotReady` is temporary — the assets are still downloading, or the
///   device is too hot or too low on battery. Retrying later works.
///
/// Collapsing those into "unavailable" would be the same mistake as reporting a
/// failed query, an empty result and an unreachable project as one empty state,
/// which `ErrorIssueDetailView.unavailableStack` exists to avoid.
enum OnDeviceModelReadiness: Equatable, Sendable {
    case ready
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    /// The device's language is not one the model handles. Checked up front
    /// because the alternative is a `GenerationError.unsupportedLanguageOrLocale`
    /// thrown *after* the reader has tapped a button and watched a spinner.
    case languageUnsupported
    /// A reason added to `UnavailableReason` after this build was compiled.
    case unrecognised

    var isReady: Bool { self == .ready }

    /// What to say in place of the summary control. Never phrased as a failure:
    /// nothing has gone wrong when a device simply does not have the feature.
    var explanation: String {
        switch self {
        case .ready:
            ""
        case .deviceNotEligible:
            "Summaries need Apple Intelligence, which this device doesn't support."
        case .notEnabled:
            "Summaries need Apple Intelligence, which is turned off. You can turn it on in Settings › Apple Intelligence & Siri."
        case .modelNotReady:
            "Apple Intelligence isn't ready yet — the model may still be downloading, or the device may be low on battery. Try again later."
        case .languageUnsupported:
            "Apple's on-device model doesn't support this device's language yet, so GetHog won't try to summarise in it."
        case .unrecognised:
            "Apple Intelligence isn't available on this device right now."
        }
    }

    /// Maps Apple's availability, plus our own locale check, onto one answer.
    ///
    /// Split out from `OnDeviceModel.readiness` and given the locale flag as a
    /// parameter purely so it can be tested: `SystemLanguageModel` has no
    /// initialiser that produces a chosen availability, so the *mapping* is the
    /// only part of this file a unit test can reach. See
    /// `OnDeviceSummaryTests.readinessNamesEveryUnavailableReason`.
    static func reading(
        _ availability: SystemLanguageModel.Availability,
        supportsLocale: Bool
    ) -> OnDeviceModelReadiness {
        switch availability {
        case .available:
            // Locale is checked second on purpose. An ineligible device reports
            // `supportedLanguages` as an empty set, and reporting that as
            // "your language isn't supported" would send the reader looking for
            // a language setting that would not help.
            return supportsLocale ? .ready : .languageUnsupported
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unrecognised
            }
        }
    }
}

/// The one place that asks the system whether summarisation is possible.
enum OnDeviceModel {

    /// Reads the current availability.
    ///
    /// `SystemLanguageModel` is `Observable`, so reading `availability` inside a
    /// SwiftUI `body` registers a dependency and the view re-renders if the
    /// reader turns Apple Intelligence on while the screen is up. That is why
    /// this is a plain function called from `body` rather than something cached
    /// in a `@State` on appear — a cached answer would leave the "turn it on in
    /// Settings" copy on screen after they had done exactly that.
    static func readiness(
        _ model: SystemLanguageModel = SystemLanguageModel.default,
        locale: Locale = .current
    ) -> OnDeviceModelReadiness {
        OnDeviceModelReadiness.reading(
            model.availability,
            supportsLocale: model.supportsLocale(locale)
        )
    }
}
