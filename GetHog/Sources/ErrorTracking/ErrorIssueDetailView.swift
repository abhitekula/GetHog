import GetHogKit
import SwiftUI

/// What GetHog can honestly say about a single error issue.
///
/// Everything shown here comes from the issue summary the query returns. Stack
/// frames are deliberately absent — see `stackTraceNote`.
struct ErrorIssueDetailView: View {
    let issue: ErrorIssue

    @Environment(AppModel.self) private var model

    private var webURL: URL? { model.webURL(path: "error_tracking/\(issue.id)") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                impact
                if issue.function?.isEmpty == false || issue.library?.isEmpty == false {
                    origin
                }
                stackTraceNote
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
        .navigationTitle(issue.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let webURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: webURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share a link to this issue")
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(issue.name)
                        .font(.title3.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    StatusPill(text: issue.statusTitle, tint: issue.statusTint)
                }

                if let description = issue.issueDescription, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if issue.firstSeen != nil || issue.lastSeen != nil {
                    Divider()
                    seenRow("First seen", issue.firstSeen)
                    seenRow("Last seen", issue.lastSeen)
                }
            }
        }
    }

    @ViewBuilder
    private func seenRow(_ title: String, _ date: Date?) -> some View {
        if let date {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                        .font(.subheadline.monospacedDigit())
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(title) \(date.formatted(date: .abbreviated, time: .shortened)), \(date.formatted(.relative(presentation: .named)))"
            )
        }
    }

    // MARK: - Impact

    private var impact: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Impact")
                    .font(.headline)

                // Three columns when they fit, stacked rows when the text is too
                // large — the figures must never be shaved down to fit.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        impactFigure("Users", issue.users)
                        Divider().frame(height: 40)
                        impactFigure("Sessions", issue.sessions)
                        Divider().frame(height: 40)
                        impactFigure("Occurrences", issue.occurrences)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        impactFigure("Users", issue.users, alignment: .leading)
                        impactFigure("Sessions", issue.sessions, alignment: .leading)
                        impactFigure("Occurrences", issue.occurrences, alignment: .leading)
                    }
                }
            }
        }
    }

    private func impactFigure(
        _ title: String,
        _ value: Double,
        alignment: HorizontalAlignment = .center
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(value.compactFormatted)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value.formatted(.number.precision(.fractionLength(0)))) \(title.lowercased())")
    }

    // MARK: - Origin

    private var origin: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Origin")
                    .font(.headline)
                if let function = issue.function, !function.isEmpty {
                    detailRow("Function", function, monospaced: true)
                }
                if let library = issue.library, !library.isEmpty {
                    detailRow("Library", library, monospaced: false)
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String, monospaced: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }

    // MARK: - Stack trace

    /// Symbolication, source maps and frame grouping all happen server-side and
    /// are rendered by the web console. A half-resolved trace — raw offsets,
    /// minified frames — would look like data while being useless, so the app
    /// says what it doesn't have and hands over.
    private var stackTraceNote: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Stack trace", systemImage: "text.alignleft")
                    .font(.headline)

                Text("GetHog doesn't render stack traces. Symbolicated frames and source-mapped code live in the PostHog web console.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let webURL {
                    Link(destination: webURL) {
                        Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                            .font(.subheadline.weight(.medium))
                    }
                } else {
                    Text("Sign in to a project to open this issue on the web.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
