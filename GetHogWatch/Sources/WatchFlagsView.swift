import GetHogKit
import GetHogUI
import SwiftUI

/// The confirm-then-authenticate ladder, pure so every transition is pinned by
/// a test.
///
/// A write reaches PostHog only through
/// `idle → confirming → authenticating → writing`, and each rung can fall back
/// only to `idle` or `failed`. Nothing here can be skipped by a view: the
/// mutating methods each guard on the step they are allowed to leave, so a
/// double tap or a re-entrant task cannot walk the ladder twice.
struct FlagToggleFlow: Equatable {

    enum Step: Equatable {
        case idle
        case confirming(flagID: Int, key: String, desired: Bool)
        case authenticating(flagID: Int, key: String, desired: Bool)
        case writing(flagID: Int, key: String, desired: Bool)
        case failed(String)
    }

    private(set) var step: Step = .idle

    mutating func propose(flag: SharedSnapshot.Flag) {
        guard case .idle = step else { return }
        step = .confirming(flagID: flag.id, key: flag.key, desired: !flag.active)
    }

    mutating func cancel() { step = .idle }

    mutating func confirm() {
        guard case .confirming(let id, let key, let desired) = step else { return }
        step = .authenticating(flagID: id, key: key, desired: desired)
    }

    /// Fails **closed**. A gate that could not confirm the wearer is not a
    /// reason to proceed on a credential that can change a flag for everybody
    /// in the project.
    mutating func authenticated(_ ok: Bool) {
        guard case .authenticating(let id, let key, let desired) = step else { return }
        step = ok
            ? .writing(flagID: id, key: key, desired: desired)
            : .failed("Couldn't confirm it's you. The flag was not changed.")
    }

    mutating func finished(error: String?) {
        guard case .writing = step else { return }
        step = error.map(Step.failed) ?? .idle
    }
}

/// Page 3: a shortlist read view.
///
/// Tapping a row *proposes* a toggle; nothing is written without the dialog and
/// the device-owner gate behind it. The list is capped rather than scrollable
/// to the end of the project's flags — a wrist is not where anyone audits a
/// hundred flags, and the footer says which ones these are.
struct WatchFlagsView: View {
    let model: WatchModel
    @State private var flow = FlagToggleFlow()

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.shortlistFlags) { flag in
                    Button {
                        flow.propose(flag: flag)
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            Circle()
                                .fill(flag.active ? Theme.Status.good : Theme.hairline)
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            Text(flag.key)
                                .font(Theme.Typography.body)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityLabel("\(flag.key), \(flag.active ? "on" : "off")")
                }
                footer
            }
            .navigationTitle("Flags")
            .confirmationDialog(
                dialogTitle,
                isPresented: confirmingBinding,
                titleVisibility: .visible
            ) {
                Button(dialogVerb) { Task { await run() } }
                Button("Cancel", role: .cancel) { flow.cancel() }
            } message: {
                Text("This changes the flag for everyone in this project.")
            }
            .alert("Flag not changed", isPresented: failedBinding) {
                Button("OK") { flow.cancel() }
            } message: {
                if case .failed(let message) = flow.step { Text(message) }
            }
            .overlay {
                if case .writing = flow.step { ProgressView() }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if model.shortlistFlags.isEmpty {
            Text("No flags yet.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.tertiary)
        } else {
            Text("First \(WatchModel.flagShortlistCap) flags")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.tertiary)
        }
        if model.watchesDegraded {
            // Same fact the Health page states, said once more where a write
            // is possible: an out-of-date watch app took only part of what the
            // phone sent, and this is the page that changes shared state.
            Text("This watch app is older than GetHog on your iPhone; some settings didn't transfer.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }

    private var dialogTitle: String {
        guard case .confirming(_, let key, let desired) = flow.step else { return "" }
        return "Turn \(key) \(desired ? "on" : "off")?"
    }

    private var dialogVerb: String {
        guard case .confirming(_, _, let desired) = flow.step else { return "Confirm" }
        return desired ? "Turn on" : "Turn off"
    }

    private var confirmingBinding: Binding<Bool> {
        Binding(
            get: { if case .confirming = flow.step { true } else { false } },
            set: { if !$0, case .confirming = flow.step { flow.cancel() } }
        )
    }

    private var failedBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = flow.step { true } else { false } },
            set: { if !$0 { flow.cancel() } }
        )
    }

    private func run() async {
        flow.confirm()
        guard case .authenticating(let id, let key, let desired) = flow.step else { return }
        let ok = await model.authenticate("Confirm changing the \(key) flag")
        flow.authenticated(ok)
        guard case .writing = flow.step else { return }
        flow.finished(error: await model.setFlag(id: id, active: desired))
    }
}
