import GetHogKit
import GetHogUI
import SwiftUI

/// Page 4: one bounded two-line identity per event.
///
/// The caps live in `WatchActivity`, not here, so the view can only draw what
/// the reducer let through. There is no detail screen behind a row on purpose:
/// the rows carry four columns and none of them is `properties`, so a tap
/// would open a screen with nothing on it that the row does not already say.
struct WatchActivityView: View {
    let model: WatchModel

    var body: some View {
        NavigationStack {
            List {
                if let failure = model.activityRefreshFailure {
                    WatchSectionFailureView(
                        failure: failure,
                        isRefreshing: model.isExplicitRefreshInFlight
                    ) {
                        Task { await model.retry() }
                    }
                }
                ForEach(model.activity) { line in
                    let identity = WatchActivityIdentityPresentation(event: line.event)
                    VStack(alignment: .leading) {
                        Text(identity.displayText)
                            .font(Theme.Typography.body)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(identity.accessibilityLabel)
                        if let timestamp = line.timestamp {
                            Text(timestamp, format: .relative(presentation: .named))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Ink.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                footer
            }
            .navigationTitle("Activity")
        }
    }

    /// Three states, not two.
    ///
    /// The window and the cap are stated rather than implied — a feed that
    /// stops after 25 rows without saying so reads as "that is all that
    /// happened" — and an empty list is only reported as *no events* when the
    /// query actually ran. Before it has, the honest answer is that nothing
    /// has been asked yet.
    @ViewBuilder private var footer: some View {
        Text(WatchActivityFooter.text(
            lineCount: model.activity.count,
            capturedAt: model.activityCapturedAt,
            now: Date()
        ))
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Ink.tertiary)
    }
}

/// Preserves the event identity while giving SwiftUI legal wrap points inside
/// identifier-shaped names. An underscore remains visible; the following
/// zero-width space is only a line-break opportunity.
struct WatchActivityIdentityPresentation: Equatable {
    static let breakOpportunity = "\u{200B}"

    let displayText: String
    let accessibilityLabel: String

    init(event: String) {
        displayText = event.replacingOccurrences(
            of: "_",
            with: "_\(Self.breakOpportunity)"
        )
        accessibilityLabel = event
    }
}

/// Pure, so the three sentences are pinned by tests rather than by a
/// screenshot.
enum WatchActivityFooter {
    static func text(lineCount: Int, capturedAt: Date?, now: Date) -> String {
        guard let capturedAt else { return "Not checked yet" }
        // The window is the budget's, not a literal beside it: the sentence
        // and the `WHERE timestamp >` floor have to be the same day or the
        // page is describing a query it did not make.
        let hours = WatchModel.budget.hours
        let age = WatchAge.stamp(capturedAt: capturedAt, now: now).lowercasedStamp
        let boundedCount = min(max(lineCount, 0), WatchActivity.maxLines)
        if boundedCount == 0 { return "No events in the last \(hours) h · \(age)" }
        if boundedCount < WatchActivity.maxLines {
            return "\(boundedCount) newest · last \(hours) h · \(age)"
        }
        return "Newest \(WatchActivity.maxLines) shown · last \(hours) h · \(age)"
    }
}

private extension String {
    /// "Updated 2 h ago" reads as a heading; mid-sentence it wants a lower
    /// case first letter and nothing else changed.
    var lowercasedStamp: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
