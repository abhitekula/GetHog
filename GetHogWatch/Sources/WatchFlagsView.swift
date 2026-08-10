import GetHogKit
import GetHogUI
import SwiftUI

/// The confirm-then-authenticate ladder, pure so every transition is pinned by
/// a test.
///
/// A write reaches PostHog only through
/// `idle → confirming → authenticating → writing`, and each rung can fall back
/// only to `idle` or `failed`.
struct FlagToggleFlow: Equatable {

    /// What a tap decided, captured as one value.
    ///
    /// It exists because the step alone cannot carry it far enough. SwiftUI
    /// sets a `confirmationDialog`'s `isPresented` binding to false
    /// *synchronously with the tap*, before the button's `Task` body runs — so
    /// the dismissal's `cancel()` had already put the flow back to `.idle` by
    /// the time the write attempted to read what to write. Every guard
    /// no-opped, and the toggle silently did nothing at all: safe, because it
    /// fails closed, and completely dead.
    ///
    /// So the tap captures this at dialog-construction time and hands it to
    /// `confirm(_:)`, which does not consult the step for the values.
    struct Pending: Equatable {
        let flagID: Int
        let key: String
        let desired: Bool
    }

    enum Step: Equatable {
        case idle
        case confirming(Pending)
        case authenticating(Pending)
        case writing(Pending)
        case failed(String)
    }

    private(set) var step: Step = .idle

    /// The proposal the dialog is asking about, and nothing else — after any
    /// dismissal this is `nil`, which is exactly why the tap must have taken
    /// its copy before then.
    var pending: Pending? {
        if case .confirming(let pending) = step { return pending }
        return nil
    }

    mutating func propose(flag: SharedSnapshot.Flag) {
        guard case .idle = step else { return }
        step = .confirming(Pending(flagID: flag.id, key: flag.key, desired: !flag.active))
    }

    mutating func cancel() { step = .idle }

    /// The dialog going away for any reason other than the action button.
    mutating func dismissed() {
        if case .confirming = step { step = .idle }
    }

    /// Advances from a proposal the caller captured, returning whether it may
    /// proceed.
    ///
    /// `.idle` is accepted, and that is the fix rather than a hole: the only
    /// way to hold a `Pending` is to have been handed one by a dialog that was
    /// itself only built from a `.confirming` step, and the dismissal that
    /// races the tap is precisely what leaves the step at `.idle`. What is
    /// still refused is a *second* ladder — anything already authenticating,
    /// writing, or sitting on a failure — so a double tap cannot spend two
    /// writes.
    mutating func confirm(_ pending: Pending) -> Bool {
        switch step {
        case .idle, .confirming:
            step = .authenticating(pending)
            return true
        case .authenticating, .writing, .failed:
            return false
        }
    }

    /// Fails **closed**. A gate that could not confirm the wearer is not a
    /// reason to proceed on a credential that can change a flag for everyone
    /// in the project.
    mutating func authenticated(_ ok: Bool) {
        guard case .authenticating(let pending) = step else { return }
        step = ok
            ? .writing(pending)
            : .failed("Couldn't confirm it's you. The flag was not changed.")
    }

    mutating func finished(error: String?) {
        guard case .writing = step else { return }
        step = error.map(Step.failed) ?? .idle
    }
}

/// Owns the ladder and drives it.
///
/// A reference type rather than the view's own `@State` value because the
/// drive is asynchronous and `inout` cannot cross an `await` — and because the
/// ordering that broke this feature (dismissal first, tap's `Task` second) is
/// only testable if a test can reach the same object the view mutates, in the
/// same order the runtime does.
@MainActor
@Observable
final class FlagToggleController {
    private(set) var flow = FlagToggleFlow()

    func propose(flag: SharedSnapshot.Flag) { flow.propose(flag: flag) }
    func cancel() { flow.cancel() }
    func dismissed() { flow.dismissed() }

    /// The whole of what the confirm button does, taking the proposal it
    /// captured rather than re-reading a step the dismissal has already reset.
    func run(_ pending: FlagToggleFlow.Pending, on model: WatchModel) async {
        guard flow.confirm(pending) else { return }
        let ok = await model.authenticate("Confirm changing the \(pending.key) flag")
        flow.authenticated(ok)
        guard case .writing = flow.step else { return }
        flow.finished(error: await model.setFlag(id: pending.flagID, active: pending.desired))
    }
}

/// Page 3: a shortlist read view.
///
/// Tapping a row *proposes* a toggle; nothing is written without the dialog and
/// the device-owner gate behind it. The list is capped at what one budgeted
/// page fetches rather than scrolling the project's whole flag set — a wrist is
/// not where anyone audits a hundred flags, and the footer says which these
/// are.
struct WatchFlagsView: View {
    let model: WatchModel
    @State private var toggle = FlagToggleController()

    var body: some View {
        NavigationStack {
            List {
                switch model.flagsContentState {
                case .needsCredential:
                    stateText("Connect to PostHog first")
                case .notChecked:
                    stateText("Flags not checked yet.")
                case .loading:
                    HStack(spacing: Theme.Space.s) {
                        ProgressView()
                        Text("Checking flags…")
                            .font(Theme.Typography.caption)
                    }
                case .empty:
                    stateText("No flags yet.")
                case .rows(let flags, _):
                    flagRows(flags)
                    rowsFooter
                case .carried(let flags, let failure, _):
                    WatchSectionFailureView(
                        failure: failure,
                        isRefreshing: model.isExplicitRefreshInFlight
                    ) {
                        Task { await model.retry() }
                    }
                    flagRows(flags)
                case .failure(let failure):
                    WatchSectionFailureView(
                        failure: failure,
                        isRefreshing: model.isExplicitRefreshInFlight
                    ) {
                        Task { await model.retry() }
                    }
                }

                if model.watchesDegraded {
                    // Same fact the Health page states, said once more where a
                    // write is possible: an out-of-date watch app took only
                    // part of what the phone sent.
                    Text(WatchHealthCopy.degradedFooter)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }
            .navigationTitle("Flags")
            .confirmationDialog(
                dialogTitle,
                isPresented: confirmingBinding,
                titleVisibility: .visible
            ) {
                // `pending` is read here, while the dialog is being built and
                // the step is still `.confirming`, and captured by the action
                // closure. Reading it inside the closure would read it after
                // the dismissal, which is the bug this shape exists to close.
                if let pending = toggle.flow.pending {
                    Button(pending.desired ? "Turn on" : "Turn off") {
                        Task { await toggle.run(pending, on: model) }
                    }
                }
                Button("Cancel", role: .cancel) { toggle.cancel() }
            } message: {
                Text("This changes the flag for everyone in this project.")
            }
            .alert("Flag not changed", isPresented: failedBinding) {
                Button("OK") { toggle.cancel() }
            } message: {
                if case .failed(let message) = toggle.flow.step { Text(message) }
            }
            .overlay {
                if case .writing = toggle.flow.step { ProgressView() }
            }
        }
    }

    @ViewBuilder private func flagRows(_ flags: [SharedSnapshot.Flag]) -> some View {
        ForEach(flags) { flag in
            Button {
                toggle.propose(flag: flag)
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Circle()
                        .fill(flag.active ? Theme.Status.good : Theme.hairline)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(flag.key)
                        .font(Theme.Typography.body)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityLabel("\(flag.key), \(flag.active ? "on" : "off")")
        }
    }

    private func stateText(_ copy: String) -> some View {
        Text(copy)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Ink.tertiary)
    }

    private var rowsFooter: some View {
        Text("First \(WatchModel.flagShortlistCap) flags")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Ink.tertiary)
    }

    private var dialogTitle: String {
        guard let pending = toggle.flow.pending else { return "" }
        return "Turn \(pending.key) \(pending.desired ? "on" : "off")?"
    }

    private var confirmingBinding: Binding<Bool> {
        Binding(
            get: { toggle.flow.pending != nil },
            set: { if !$0 { toggle.dismissed() } }
        )
    }

    private var failedBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = toggle.flow.step { true } else { false } },
            set: { if !$0 { toggle.cancel() } }
        )
    }
}
