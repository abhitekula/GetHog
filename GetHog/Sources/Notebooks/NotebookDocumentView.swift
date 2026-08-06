import GetHogKit
import GetHogUI
import SwiftUI

// Rendering a notebook body.
//
// The rule the whole file is built around: **a block the reader cannot see is
// indistinguishable from a block the author never wrote.** A notebook is a
// document whose point is often the charts in it, so a renderer that quietly
// skips what it does not understand turns an incomplete document into a shorter
// one, and gives the reader no way to tell which they are holding. Every case
// below therefore ends in something on screen — a chart, a card naming the
// object, or a card naming the node type. None of them ends in nothing.
//
// This is the same decision `InsightRenderModel.unsupported` records for insight
// display types, and it is here for the same reason: a `WorldMap` insight that
// fell through to an empty line chart read as *broken* rather than as
// unsupported, and cost real time to diagnose.

// MARK: - Inline text

extension [NotebookInline] {
    /// The runs as one styled string.
    ///
    /// Built run by run rather than by handing PostHog's text to
    /// `AttributedString(markdown:)`: the marks are already parsed in the tree,
    /// and re-parsing the text as markdown would make `**` inside a code span
    /// bold and would swallow a stray bracket. A run whose marks are *not*
    /// understood still contributes its text — losing a word mid-sentence is far
    /// worse than losing its styling.
    var styled: AttributedString {
        reduce(into: AttributedString()) { result, run in
            var piece = AttributedString(run.text)
            if run.isBold { piece.inlinePresentationIntent = .stronglyEmphasized }
            if run.isItalic {
                piece.inlinePresentationIntent =
                    (piece.inlinePresentationIntent ?? []).union(.emphasized)
            }
            if run.isStrikethrough { piece.strikethroughStyle = .single }
            if run.isCode {
                piece.font = .callout.monospaced()
                piece.foregroundColor = Theme.accent
            }
            if let href = run.href, let url = URL(string: href) {
                piece.link = url
            }
            result += piece
        }
    }
}

// MARK: - Block row

/// One block of a notebook, as a row.
///
/// Deliberately a row rather than a card. A notebook is prose first: wrapping
/// every paragraph in a card would turn a document into a feed, and the reader
/// would lose the sense of continuous text that is the reason to write one.
/// Only the embedded objects get cards, because they *are* discrete objects.
struct NotebookBlockRow: View {
    let block: NotebookBlock
    /// Held by the screen, not by the row — see `NotebookInsightCache`. A row in
    /// a `List` is destroyed and rebuilt as it scrolls, so a fetch recorded in
    /// row state would be repeated every time the reader scrolls back.
    let insightCache: NotebookInsightCache

    var body: some View {
        switch block {
        case .heading(let level, let inlines):
            Text(inlines.styled)
                .font(headingFont(level))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? Theme.Space.s : 0)
                // Headings are the notebook's structure, so they are announced
                // as headings rather than as another line of prose — that is
                // what makes rotor navigation work on a long document.
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let inlines):
            Text(inlines.styled)
                .font(.callout)
                .textSelection(.enabled)

        case .listItem(let item):
            NotebookListItemRow(item: item)

        case .quote(let inlines):
            HStack(alignment: .top, spacing: Theme.Space.m) {
                // A 3pt bar, not a leading quote glyph: the bar scales with the
                // text at AX5 where a fixed glyph would sit level with the first
                // line of a six-line quotation.
                Capsule()
                    .fill(Theme.accent.opacity(0.5))
                    .frame(width: 3)
                Text(inlines.styled)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(Theme.Ink.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Quote. \(inlines.plainText)")

        case .code(let language, let text):
            NotebookCodeBlock(language: language, code: text)

        case .rule:
            Divider()
                .padding(.vertical, Theme.Space.xs)
                .accessibilityHidden(true)

        case .embed(let embed):
            NotebookEmbedRow(embed: embed, insightCache: insightCache)

        case .unsupported(let node):
            NotebookUnsupportedBlock(node: node)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private struct NotebookListItemRow: View {
    let item: NotebookListItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            marker
            Text(item.inlines.styled)
                .font(.callout)
                .textSelection(.enabled)
        }
        // Indent by depth. Nested lists were flattened in the model, so the
        // indent is the only thing carrying the nesting — which is why it is a
        // real offset rather than a leading glyph change.
        .padding(.leading, CGFloat(item.depth) * Theme.Space.l)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var marker: some View {
        switch item.marker {
        case .bullet:
            Text("•")
                .font(.callout)
                .foregroundStyle(Theme.Ink.tertiary)
        case .number(let n):
            Text("\(n).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.Ink.tertiary)
        case .task(let done):
            // Not colour alone: the box is filled *and* changes symbol, so the
            // done state survives a monochrome display and a colour-blind reader.
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.callout)
                .foregroundStyle(done ? Theme.accent : Theme.Ink.tertiary)
        }
    }

    private var accessibilityLabel: String {
        let text = item.inlines.plainText
        return switch item.marker {
        case .bullet: text
        case .number(let n): "\(n). \(text)"
        case .task(let done): done ? "Done. \(text)" : "Not done. \(text)"
        }
    }
}

private struct NotebookCodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let language {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            // Wraps rather than scrolling horizontally.
            //
            // A horizontal `ScrollView` was the first attempt, on the argument
            // that wrapping loses the indentation that is most of SQL's
            // readability. Two things ruled it out. It nests a horizontal
            // scroller inside the `List`'s vertical one, which is an awkward
            // gesture on a phone; and `ImageRenderer` cannot draw
            // `ScrollView`-clipped content, so the block came out as an **empty
            // grey rectangle** in every render — meaning the one cheap way to
            // look at this screen could never show whether the code was there.
            // A design that cannot be inspected is the wrong design here.
            //
            // Wrapping keeps each source line's own leading indentation; only
            // over-long lines fold, and they fold visibly.
            Text(code)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                // Without this the block truncates to two lines with an ellipsis
                // rather than wrapping — seen in the ImageRenderer output, not
                // guessed. A `Text` in a stack takes its ideal height unless told
                // to grow vertically at the offered width.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.m)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Theme.pageBackground)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(language ?? "Code") block. \(code)")
    }
}

// MARK: - Unsupported

/// A node this build does not know how to draw.
///
/// The dashed border and the explicit sentence are the point. PostHog's own
/// shared-notebook renderer does the same thing — its fallback card reads "Node
/// cannot be rendered / This node type is not supported in shared notebooks" —
/// which is a useful confirmation that even the console cannot draw every node
/// everywhere, and that saying so is the accepted answer.
///
/// The raw type string is shown, not hidden. Whoever hits this card is the
/// person best placed to report which node is missing, and "mermaid" is a
/// filable bug report where "a block" is not.
struct NotebookUnsupportedBlock: View {
    let node: NotebookUnsupportedNode

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label {
                Text("\(node.label) — not shown here")
                    .font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: "questionmark.square.dashed")
                    .foregroundStyle(Theme.Status.warningInk)
            }

            Text("This notebook has a \(node.rawType) block. GetHog doesn't draw this kind yet — open the notebook in PostHog to see it.")
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let text = node.text {
                // Whatever the author typed is better than an empty card: for a
                // mermaid or a formula block the text *is* the content.
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Ink.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Theme.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.label). Not shown in GetHog. Node type \(node.rawType).")
    }
}
