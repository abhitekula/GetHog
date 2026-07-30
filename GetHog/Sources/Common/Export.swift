import CoreTransferable
import GetHogKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Rasterises a chart for sharing.
@MainActor
enum ChartImageRenderer {

    /// A shared chart is almost always viewed somewhere other than a phone, so
    /// it is composed at a desktop-ish width. Inheriting the ~390pt layout the
    /// user is looking at produces a tall, cramped image with unreadable axis
    /// labels the moment it lands in Slack.
    static let exportWidth: CGFloat = 900

    static func png(title: String, model: InsightRenderModel, width: CGFloat = exportWidth) -> Data? {
        png(of: card(title: title, model: model, width: width))
    }

    static func png(of content: some View, scale: CGFloat = 3) -> Data? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        // Paired with the card's own fill below. A transparent PNG pasted into
        // a dark-mode Slack or Notes draws dark ink on a dark surface and reads
        // as an empty image.
        renderer.isOpaque = true
        return renderer.uiImage?.pngData()
    }

    private static func card(title: String, model: InsightRenderModel, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
            InsightChartView(model: model, compact: false)
        }
        .padding(28)
        .frame(width: width, alignment: .leading)
        .background(Theme.pageBackground)
    }
}

/// An insight as something the system can move around.
///
/// Carries all three useful shapes so one value serves `ShareLink`, an iPad
/// drag onto Numbers, and a drop into a plain text field.
struct ExportableInsight: Transferable {
    let title: String
    let model: InsightRenderModel

    /// `nil` for insights the app never decoded — see `InsightCSV`.
    var csv: String? { InsightCSV.encode(model) }

    static var transferRepresentation: some TransferRepresentation {
        // PNG leads: it is what a share sheet and a drop onto Photos or a chat
        // want, and it is the representation every destination understands.
        DataRepresentation(exportedContentType: .png) { insight in
            try await insight.pngData()
        }
        .suggestedFileName { $0.fileName(extension: "png") }

        DataRepresentation(exportedContentType: .commaSeparatedText) { insight in
            try insight.csvData()
        }
        .suggestedFileName { $0.fileName(extension: "csv") }

        ProxyRepresentation { $0.title }
    }

    func pngData() async throws -> Data {
        guard let data = await ChartImageRenderer.png(title: title, model: model) else {
            throw ExportError.imageRenderFailed
        }
        return data
    }

    func csvData() throws -> Data {
        guard let csv else { throw ExportError.notExportable }
        return Data(csv.utf8)
    }

    func fileName(extension ext: String) -> String {
        "\(Self.sanitized(title)).\(ext)"
    }

    /// `/` separates path components on iOS and `:` still does in Finder's
    /// classic mapping, so a title like "Signups / week" yields a file the
    /// receiving app cannot write. The rest are Windows-illegal, and exports
    /// routinely end up on a shared drive.
    static func sanitized(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: #"/:\?%*|"<>"#))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Insight" : cleaned
    }
}

/// PNG-only projection of an insight.
///
/// The share menu offers "image" and "CSV" as separate choices, so each entry
/// has to commit to one type. A multi-representation item lets the *receiving*
/// app pick, which would make the two entries behave identically.
struct InsightChartImage: Transferable {
    let insight: ExportableInsight

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { try await $0.insight.pngData() }
            .suggestedFileName { $0.insight.fileName(extension: "png") }
    }
}

/// CSV-only projection, for the same reason in reverse.
struct InsightCSVFile: Transferable {
    let insight: ExportableInsight

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { try $0.insight.csvData() }
            .suggestedFileName { $0.insight.fileName(extension: "csv") }
    }
}

enum ExportError: Error {
    case imageRenderFailed
    /// The insight has no drawable model, so there is no honest CSV for it.
    case notExportable
}

// MARK: - Save to Files

/// The same CSV `ShareLink` hands to the share sheet, as a document the user can
/// put somewhere and keep.
///
/// A different destination rather than a second route to the same one: the share
/// sheet is for sending a number to a person, while this is for filing it next
/// to the rest of the week's work, in iCloud Drive or on a synced volume. The
/// bytes are `InsightCSV`'s either way — there is exactly one encoder, and an
/// export that disagreed with the chart would be worse than no export at all.
struct InsightCSVDocument: FileDocument {

    /// Export-only. GetHog has nothing to do with a CSV somebody hands it,
    /// and claiming otherwise would put the app in the Files "Open with" list.
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.commaSeparatedText]

    let insight: ExportableInsight

    init(insight: ExportableInsight) {
        self.insight = insight
    }

    /// Unreachable while `readableContentTypes` is empty, and required by the
    /// protocol regardless. Throwing beats a stub that would silently invent an
    /// empty insight if the type ever became readable.
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try insight.csvData())
    }
}

/// Carries a "save to Files" request from a menu item to the sheet that performs
/// it.
///
/// The indirection is forced: a menu's content is built as menu *elements*, and
/// a presentation modifier attached in there goes away with the menu the moment
/// it closes, so the sheet never appears. The request is recorded here instead
/// and presented by `insightCSVExporter()`, which is attached to a view that
/// outlives every menu in the window.
@MainActor
@Observable
final class InsightExportCoordinator {

    fileprivate var document: InsightCSVDocument?
    fileprivate var isPresented = false

    func export(_ insight: ExportableInsight) {
        // `.unsupported` insights decode to nothing drawable, so there is no
        // honest CSV to write. The menu already hides the entry; this is the
        // second lock on the same door.
        guard insight.csv != nil else { return }
        document = InsightCSVDocument(insight: insight)
        isPresented = true
    }

    fileprivate var defaultFilename: String {
        document.map { ExportableInsight.sanitized($0.insight.title) } ?? "Insight"
    }
}

private struct InsightCSVExportModifier: ViewModifier {

    @State private var coordinator = InsightExportCoordinator()

    func body(content: Content) -> some View {
        content
            .environment(coordinator)
            .fileExporter(
                isPresented: $coordinator.isPresented,
                document: coordinator.document,
                contentType: .commaSeparatedText,
                defaultFilename: coordinator.defaultFilename
            ) { _ in
                // Nothing to report either way: a successful save is visible in
                // Files, and the picker has already shown its own error. The
                // document is dropped so a later export cannot inherit it.
                coordinator.document = nil
            }
    }
}

extension View {
    /// Hosts the "save to Files" sheet, and offers everything below it the
    /// coordinator that opens one. Attach once per window scene.
    func insightCSVExporter() -> some View {
        modifier(InsightCSVExportModifier())
    }
}

/// The share actions themselves, unwrapped.
///
/// Kept separate from `InsightShareMenu` so a context menu can show them flat
/// rather than burying them one level down inside a second menu.
struct InsightShareMenuItems: View {
    let title: String
    let model: InsightRenderModel

    /// Optional so the menu still builds in a preview, or in any window that
    /// has not attached `insightCSVExporter()`; the entry simply isn't offered
    /// there rather than being offered and doing nothing.
    @Environment(InsightExportCoordinator.self) private var exporter: InsightExportCoordinator?

    private var insight: ExportableInsight {
        ExportableInsight(title: title, model: model)
    }

    var body: some View {
        // An insight the app never decoded has nothing to export in any form —
        // the PNG would be a photograph of the "not drawn on mobile yet" card.
        // Everything goes rather than offering something useless; those tiles
        // already carry their own "Open in PostHog" link.
        if let csv = insight.csv {
            ShareLink(
                item: InsightChartImage(insight: insight),
                preview: SharePreview(title)
            ) {
                Label("Share chart image", systemImage: "photo")
            }
            .accessibilityLabel("Share chart image")

            ShareLink(
                item: InsightCSVFile(insight: insight),
                preview: SharePreview(title)
            ) {
                Label("Export CSV", systemImage: "tablecells")
            }
            .accessibilityLabel("Export data as CSV")

            // The share sheet's own "Save to Files" is three taps in and picks
            // the destination last; this is the direct route for a CSV somebody
            // means to keep rather than send.
            if let exporter {
                Button {
                    exporter.export(insight)
                } label: {
                    Label("Save CSV to Files…", systemImage: "folder")
                }
                .accessibilityLabel("Save data as a CSV file")
            }

            Button {
                UIPasteboard.general.string = csv
            } label: {
                Label("Copy CSV", systemImage: "doc.on.doc")
            }
            .accessibilityLabel("Copy data as CSV")
        }
    }
}

/// Share affordances for a single insight, as a toolbar menu.
struct InsightShareMenu: View {
    let title: String
    let model: InsightRenderModel

    var body: some View {
        if InsightCSV.encode(model) != nil {
            Menu {
                InsightShareMenuItems(title: title, model: model)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share \(title)")
        }
    }
}
