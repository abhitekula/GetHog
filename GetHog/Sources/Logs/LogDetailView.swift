import GetHogKit
import SwiftUI

// MARK: - Row surface

private extension View {
    /// The card row the log screens share, applied in one place because every
    /// section here carries it.
    func cardRow() -> some View {
        listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
    }
}

/// One log line, in full.
///
/// The list cannot show one and should not try: a row gives the message three
/// lines and then truncates, which is right for scanning and useless for the
/// thing people actually open logs for — a stack trace, a long error string, a
/// serialised payload. Before this screen existed a clipped line could be read
/// only through VoiceOver, which speaks the untruncated string; that was the
/// bug.
///
/// The order — metadata, then body — is the same one `LogRow.plainText` writes,
/// so what is copied matches what was on screen. The body goes last in both for
/// the same reason: anything printed after a stack trace is scrolled past.
struct LogDetailView: View {
    let row: LogRow

    /// Bumped, never read. `UIPasteboard` gives no feedback of its own, and a
    /// Copy button that appears to do nothing gets pressed a second time.
    @State private var copies = 0

    var body: some View {
        List {
            Section {
                // Severity leads, as glyph *and* word *and* tint — never the
                // tint alone.
                field(
                    "Severity",
                    glyph: row.severity.glyph,
                    tint: row.severity.tint,
                    value: row.severity.title
                )
                if let serviceName = row.serviceName, !serviceName.isEmpty {
                    field("Service", glyph: "server.rack", value: serviceName)
                }
                if let timestamp = row.timestamp {
                    // Absolute, not "3 hours ago" like the list row: this is the
                    // screen someone is on when they need to line the line up
                    // against a deploy or another system's clock.
                    field(
                        "Recorded",
                        glyph: "clock",
                        value: timestamp.formatted(
                            .dateTime.year().month().day().hour().minute().second()
                        )
                    )
                }
                if let traceID = row.traceID, !traceID.isEmpty {
                    // Whole, where the list row shows twelve characters to fit
                    // its column. A trace id that has been cut cannot be pasted
                    // into a search, so showing part of one is worse than none.
                    field("Trace", glyph: "point.3.connected.trianglepath.dotted", value: traceID)
                }
            } header: {
                SectionLabel(text: "Line", systemImage: "text.alignleft")
            }

            Section {
                Text(row.body)
                    .font(Theme.Typography.body.monospaced())
                    .foregroundStyle(.primary)
                    // No line limit, and `fixedSize` so the row grows to whatever
                    // the message needs instead of the List settling on a height
                    // and clipping. Monospaced because alignment is meaning in
                    // structured output — a reflowed stack trace is a different
                    // document, and by the same argument it must not be given a
                    // hyphen it does not contain: `zxx` is the ISO code for "no
                    // linguistic content", so no hyphenation dictionary applies
                    // to a symbol name or a path in this payload.
                    .typesettingLanguage(Locale.Language(identifier: "zxx"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.xs)
                    .cardRow()
            } header: {
                SectionLabel(text: "Message", systemImage: "quote.opening")
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .navigationTitle(row.serviceName ?? "Log line")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = row.plainText
                    copies += 1
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .accessibilityLabel("Copy this log line")
            }
        }
        .sensoryFeedback(.success, trigger: copies)
    }

    /// One piece of the line's provenance.
    private func field(
        _ label: String,
        glyph: String,
        tint: Color = Theme.accent,
        value: String
    ) -> some View {
        DataRow(
            glyph: glyph,
            tint: tint,
            title: label,
            subtitle: value,
            // Every value here is an identifier or a fixed-width figure, and two
            // lines rather than one because a 32-character trace id does not fit
            // on one at the larger Dynamic Type sizes — and an id truncated by
            // the layout is the exact failure this screen exists to undo.
            isSubtitleMonospaced: true,
            subtitleLineLimit: 2,
            accessory: .none
        )
        // Selection is how a single id leaves the phone without taking the whole
        // line with it.
        .textSelection(.enabled)
        .cardRow()
    }
}
