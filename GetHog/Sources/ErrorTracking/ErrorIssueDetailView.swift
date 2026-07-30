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
            // Padded per block rather than around the stack: `StatStrip` carries
            // its own insets so the figures can scroll edge to edge.
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                    .padding(.horizontal, Theme.Space.l)
                impact
                if issue.function?.isEmpty == false || issue.library?.isEmpty == false {
                    origin
                        .padding(.horizontal, Theme.Space.l)
                }
                stackTraceNote
                    .padding(.horizontal, Theme.Space.l)
            }
            .padding(.vertical, Theme.Space.l)
        }
        .pageSurface()
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

    /// The three figures that decide whether this issue is worth anyone's
    /// morning. `StatStrip` scrolls them sideways rather than stacking or
    /// compressing, so a figure is never shaved down to fit.
    private var impact: some View {
        StatStrip {
            impactFigure("Users", issue.users)
            impactFigure("Sessions", issue.sessions)
            impactFigure("Occurrences", issue.occurrences)
        }
    }

    private func impactFigure(_ title: String, _ value: Double) -> some View {
        MetricTile(label: title, value: value.compactFormatted, compact: true)
            // Spoken at full precision: "12.4K" is a reading aid, not a figure,
            // and speech has no trouble with the whole number.
            .accessibilityLabel(
                "\(value.formatted(.number.precision(.fractionLength(0)))) \(title.lowercased())"
            )
    }

    // MARK: - Origin

    private var origin: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Origin", systemImage: "arrow.triangle.branch")
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
                SectionLabel(text: "Stack trace", systemImage: "text.alignleft")

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
