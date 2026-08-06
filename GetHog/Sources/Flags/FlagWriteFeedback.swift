import GetHogUI
import SwiftUI

/// The three monotonic counters `FlagToggleController` publishes after a write,
/// read as one value.
///
/// Snapshotting them together is what makes the outcome derivable: a caller
/// holding three separate `onChange` handlers sees three unordered edges and
/// cannot tell "the write failed" from "the write succeeded and an unrelated
/// request was filed". One value, one diff, one answer.
struct FlagWriteCounts: Equatable {
    var success: Int
    var failure: Int
    var filed: Int

    init(success: Int = 0, failure: Int = 0, filed: Int = 0) {
        self.success = success
        self.failure = failure
        self.filed = filed
    }

    /// `FlagToggleController` is main-actor isolated; the value it snapshots
    /// into is not, which is the point — a plain `Equatable` struct is what
    /// `onChange` can diff and what a test can build without a controller.
    @MainActor
    init(controller: FlagToggleController) {
        self.init(
            success: controller.successCount,
            failure: controller.failureCount,
            filed: controller.filedCount
        )
    }
}

/// What a fresh counter bump means, in the vocabulary the user is shown.
enum FlagWriteSignal: Equatable, CaseIterable {
    case success
    case failure
    /// The write came back `approval_required`: the flag is unchanged and a
    /// change request is waiting for a colleague. Neither of the other two.
    case filed
}

extension FlagWriteSignal {

    /// The outcome a pair of counter snapshots describes, or `nil` when nothing
    /// moved.
    ///
    /// Failure outranks the others deliberately. The counters are monotonic and
    /// a single change can carry more than one edge — a retry that failed after
    /// an earlier success lands both — and of the three, the one a reader must
    /// not miss is the one that says their change is not live.
    static func signal(from old: FlagWriteCounts, to new: FlagWriteCounts) -> FlagWriteSignal? {
        if new.failure > old.failure { return .failure }
        if new.filed > old.filed { return .filed }
        if new.success > old.success { return .success }
        return nil
    }

    /// Short enough to read in the two seconds the capsule is up.
    var title: String {
        switch self {
        case .success: "Updated"
        case .failure: "Didn't save"
        case .filed: "Sent for approval"
        }
    }

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .filed: "clock.badge.checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .success: Theme.Status.goodInk
        case .failure: Theme.Status.criticalInk
        case .filed: Theme.Status.warningInk
        }
    }
}

#if os(macOS)

/// Says out loud what the haptic says on a phone.
///
/// `FlagDetailView` confirms a flag write with three `sensoryFeedback` taps.
/// On the Mac those are inert — most Macs have no haptic engine — so flipping a
/// flag produced no confirmation beyond the toggle settling, and the
/// `approval_required` case produced *nothing at all* even though the flag did
/// not change. This is the same three signals in the channel this platform
/// actually has.
///
/// iOS keeps the haptics and compiles nothing from here: the modifier is the
/// identity on every other platform.
struct FlagWriteFeedbackModifier: ViewModifier {
    let counts: FlagWriteCounts

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var signal: FlagWriteSignal?
    /// Bumped with every shown signal so two identical outcomes in a row each
    /// restart the dismissal clock instead of the second one inheriting the
    /// first one's remaining time.
    @State private var shownCount = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let signal {
                    capsule(for: signal)
                        .padding(.top, Theme.Space.m)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: shownCount)
            .onChange(of: counts) { old, new in
                guard let next = FlagWriteSignal.signal(from: old, to: new) else { return }
                signal = next
                shownCount += 1
            }
            // Keyed on the counter so a second write re-arms the clock; the
            // task is cancelled and restarted rather than stacking.
            .task(id: shownCount) {
                guard signal != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                signal = nil
            }
    }

    private func capsule(for signal: FlagWriteSignal) -> some View {
        Label(signal.title, systemImage: signal.systemImage)
            .font(.callout.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(signal.tint)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            // Material, not a wash of the tint: this capsule floats over
            // whatever the detail is showing rather than sitting on a known
            // card, so the ground it needs contrast against is not knowable.
            .background(.regularMaterial, in: .capsule)
            .overlay(Capsule().strokeBorder(signal.tint.opacity(0.25)))
            .accessibilityAddTraits(.isStaticText)
    }
}

#endif

extension View {

    /// Shows a transient confirmation of the last flag write on platforms where
    /// the haptic that says the same thing does not play. The identity on iOS.
    func flagWriteFeedback(_ counts: FlagWriteCounts) -> some View {
        #if os(macOS)
        modifier(FlagWriteFeedbackModifier(counts: counts))
        #else
        self
        #endif
    }
}
