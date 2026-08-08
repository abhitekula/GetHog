import CoreTransferable
import GetHogKit
import GetHogUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
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
        #if canImport(UIKit)
        return renderer.uiImage?.pngData()
        #else
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #endif
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

// The CSV-only projection that used to sit here is now `CSVFile`, which carries
// a `CSVExport` and therefore serves the console and the feeds as well as an
// insight. There was never anything insight-shaped about a CSV.

enum ExportError: Error {
    case imageRenderFailed
    /// The insight has no drawable model, so there is no honest CSV for it.
    case notExportable
}

// MARK: - Any table, as CSV

/// A table of cells somebody may want out of the app, whatever drew it.
///
/// **Why this exists as a value rather than as another `Transferable`.** Before
/// it, everything exportable had to be an `InsightRenderModel`, so the three
/// screens holding the most obviously exportable data — the SQL console, the
/// events feed, the web-analytics tables — could export nothing at all, while
/// `InsightCSV.encode(columns:rows:)` sat in the kit, tested, with no callers.
/// The row shape those screens hold is the `/query/` row shape, which is the
/// same everywhere; only the wrapper was missing.
///
/// **`encode` is a closure, and that is the load-bearing part.** The insight
/// path builds its CSV eagerly, inside a `View` body — `if let csv =
/// insight.csv` — which is appropriate for small results but not arbitrary
/// console output. Deferring means a menu costs a row count, and bytes are built
/// once only when requested.
struct CSVExport: Sendable {
    let title: String
    let rowCount: Int
    private let encode: @Sendable () -> Data

    init(title: String, rowCount: Int, encode: @escaping @Sendable () -> Data) {
        self.title = title
        self.rowCount = rowCount
        self.encode = encode
    }

    /// A `/query/` result — the console's, the events feed's, anything built
    /// from `QueryResponse`.
    static func query(title: String, columns: [String], rows: [[JSONValue]]) -> CSVExport {
        CSVExport(title: title, rowCount: rows.count) {
            InsightCSV.data(columns: columns, rows: rows)
        }
    }

    /// A table a screen decoded into structs and re-flattened, where the header
    /// is the screen's own wording rather than the wire's. `rows` includes the
    /// header row, matching `InsightCSV.encode(rows:)`.
    static func table(title: String, rows: [[String]]) -> CSVExport {
        CSVExport(title: title, rowCount: max(rows.count - 1, 0)) {
            InsightCSV.data(rows: rows)
        }
    }

    func data() -> Data { encode() }

    var fileName: String { "\(ExportableInsight.sanitized(title)).csv" }

    var isEmpty: Bool { rowCount == 0 }
}

/// A `CSVExport` as something the share sheet and Files can take.
struct CSVFile: Transferable {
    let export: CSVExport

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { $0.export.data() }
            .suggestedFileName { $0.export.fileName }
    }
}

// MARK: - Save to Files

/// The same CSV `ShareLink` hands to the share sheet, as a document the user can
/// put somewhere and keep.
///
/// A different destination rather than a second route to the same one: the share
/// sheet is for sending a number to a person, while this is for filing it next
/// to the rest of the week's work, in iCloud Drive or on a synced volume. The
/// bytes are `InsightCSV`'s either way — there is exactly one encoder, and an
/// export that disagreed with what is on screen would be worse than no export at
/// all.
struct CSVDocument {

    let export: CSVExport

    init(export: CSVExport) {
        self.export = export
    }
}

// `FileDocument` and `.fileExporter` are both unavailable on tvOS: there is no
// Files app and no document picker to present. The type itself still compiles
// everywhere so the coordinator below needs no branching — only the
// conformance, and the sheet that uses it, are absent.
#if !os(tvOS)
extension CSVDocument: FileDocument {

    /// Export-only. GetHog has nothing to do with a CSV somebody hands it,
    /// and claiming otherwise would put the app in the Files "Open with" list.
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.commaSeparatedText]

    /// Unreachable while `readableContentTypes` is empty, and required by the
    /// protocol regardless. Throwing beats a stub that would silently invent an
    /// empty table if the type ever became readable.
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: export.data())
    }
}
#endif

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
final class CSVExportCoordinator {

    fileprivate var document: CSVDocument?
    fileprivate var isPresented = false
    /// Set when a copy was refused for size. Presented as an alert by the same
    /// modifier that hosts the exporter, because that is the one view guaranteed
    /// to outlive the menu the button was in — the identical reason the file
    /// export is routed through here rather than presented from the menu.
    fileprivate var copyRefusal: String?

    /// What this app is willing to hand the system pasteboard.
    ///
    /// **A chosen budget, not a measured limit** — the point at which
    /// `UIPasteboard` actually drops or stalls on an oversized item has not been
    /// measured here, and this number should not be read as one. The reasoning
    /// is that the pasteboard is a system-wide service that copies the item out
    /// of this process, so a console result that is fine to hold and fine to
    /// write to a file is not automatically fine to put there. 8 MB is roughly
    /// 1,200 rows of the widest realistic events query, and far more of anything
    /// narrow.
    ///
    /// Only "Copy" is capped. Share and Save write the whole table: cutting an
    /// export off at an arbitrary row and not saying so is the failure mode this
    /// codebase treats as worse than no export.
    private static let pasteboardBudget = 8 << 20

    func export(_ table: CSVExport) {
        document = CSVDocument(export: table)
        isPresented = true
    }

    /// Copies, unless the file is larger than this app is prepared to put on the
    /// pasteboard — in which case it says so and copies nothing, rather than
    /// copying something truncated.
    func copy(_ table: CSVExport) {
        #if os(tvOS)
        // There is no `UIPasteboard` on tvOS and nowhere to paste into. The
        // menus that call this render nothing there (see `CSVShareMenuItems`
        // below), so this is unreachable rather than silently inert — but it
        // returns early rather than compiling a copy that cannot happen.
        return
        #else
        let data = table.data()
        guard data.count <= Self.pasteboardBudget else {
            let megabytes = Double(data.count) / 1_048_576
            copyRefusal = """
                “\(table.title)” is \(megabytes.formatted(.number.precision(.fractionLength(1)))) MB \
                as CSV, over the \(Self.pasteboardBudget >> 20) MB this app will put on the clipboard. \
                Use Share or Save to Files instead — those write the whole table.
                """
            return
        }
        UIPasteboard.general.string = String(decoding: data, as: UTF8.self)
        #endif
    }

    fileprivate var defaultFilename: String {
        document.map { ExportableInsight.sanitized($0.export.title) } ?? "Export"
    }
}

private struct CSVExportModifier: ViewModifier {

    @State private var coordinator = CSVExportCoordinator()

    func body(content: Content) -> some View {
        content
            .environment(coordinator)
            // `.fileExporter` is unavailable on tvOS, and nothing there can ask
            // for it: no menu offers "Save CSV to Files…" on that platform. The
            // alert stays on every platform — the coordinator is still handed
            // down, so any future caller that refuses a copy still gets heard.
            #if !os(tvOS)
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
            #endif
            .alert(
                "Too large to copy",
                isPresented: Binding(
                    get: { coordinator.copyRefusal != nil },
                    set: { if !$0 { coordinator.copyRefusal = nil } }
                )
            ) {
                Button("OK", role: .cancel) { coordinator.copyRefusal = nil }
            } message: {
                Text(coordinator.copyRefusal ?? "")
            }
    }
}

extension View {
    /// Hosts the "save to Files" sheet, and offers everything below it the
    /// coordinator that opens one. Attach once per window scene.
    func csvExporter() -> some View {
        modifier(CSVExportModifier())
    }

    /// The name this was attached under before it served anything but insights.
    ///
    /// Kept because its call sites — both window scenes and the iPhone insight
    /// sheet — are outside this file, and renaming across them buys nothing: the
    /// modifier they attach now hosts every CSV export in the app, which is
    /// exactly what those three attachment points were already positioned for.
    func insightCSVExporter() -> some View { csvExporter() }
}

/// The three CSV destinations, for any table.
///
/// Send it, keep it, or paste it — a deliberate set rather than one button,
/// because on a phone they are three different intentions and the share sheet
/// only serves the first well. "Save to Files" through the share sheet is three
/// taps in and picks the destination last.
///
/// Nothing here encodes during `body`. The menu is built from `rowCount`; the
/// bytes are produced inside a `ShareLink` representation or a button action.
struct CSVShareMenuItems: View {
    let export: CSVExport

    /// Optional so the menu still builds in a preview, or in any window that has
    /// not attached `csvExporter()`; the entries simply aren't offered there
    /// rather than being offered and doing nothing.
    @Environment(CSVExportCoordinator.self) private var exporter: CSVExportCoordinator?

    var body: some View {
        #if os(tvOS)
        // All three destinations are unreachable on tvOS: `ShareLink` is
        // unavailable, there is no Files app to save into, and there is no
        // pasteboard to copy to. An empty menu is the honest answer — three
        // rows that do nothing would be worse than their absence.
        EmptyView()
        #else
        ShareLink(
            item: CSVFile(export: export),
            preview: SharePreview(export.title)
        ) {
            Label("Export CSV", systemImage: "tablecells")
        }
        .accessibilityLabel("Export data as CSV")

        if let exporter {
            Button {
                exporter.export(export)
            } label: {
                Label("Save CSV to Files…", systemImage: "folder")
            }
            .accessibilityLabel("Save data as a CSV file")

            // Routed through the coordinator rather than writing
            // `UIPasteboard.general.string` here, so an oversized table is
            // refused with an explanation from a view that outlives this menu.
            Button {
                exporter.copy(export)
            } label: {
                Label("Copy CSV", systemImage: "doc.on.doc")
            }
            .accessibilityLabel("Copy data as CSV")
        }
        #endif
    }
}

/// The CSV destinations as a self-contained toolbar menu, for a screen whose
/// toolbar has nothing else to fold them into.
struct CSVShareMenu: View {
    let export: CSVExport
    var systemImage: String = "square.and.arrow.up"

    var body: some View {
        #if os(tvOS)
        // Nothing to fold in — `CSVShareMenuItems` renders nothing here — so the
        // toolbar keeps the space instead of a menu that opens on emptiness.
        EmptyView()
        #else
        Menu {
            // Naming the size in the menu rather than after the fact: a console
            // result can be anything from three rows to tens of thousands, and
            // the difference decides which of the three destinations the reader
            // wants.
            Section("\(export.rowCount.formatted()) \(export.rowCount == 1 ? "row" : "rows")") {
                CSVShareMenuItems(export: export)
            }
        } label: {
            Image(systemName: systemImage)
        }
        .accessibilityLabel("Export \(export.title)")
        .disabled(export.isEmpty)
        #endif
    }
}

extension ExportableInsight {

    /// The insight as a plain table, so it travels the same road as every other
    /// export in the app.
    ///
    /// `nil` for an `.unsupported` model, which decodes to nothing drawable and
    /// therefore has no honest CSV — the same condition `csv` reports, expressed
    /// once.
    var csvExport: CSVExport? {
        guard let rows = InsightCSV.rows(model) else { return nil }
        return .table(title: title, rows: rows)
    }
}

/// The share actions themselves, unwrapped.
///
/// Kept separate from `InsightShareMenu` so a context menu can show them flat
/// rather than burying them one level down inside a second menu.
struct InsightShareMenuItems: View {
    let title: String
    let model: InsightRenderModel

    private var insight: ExportableInsight {
        ExportableInsight(title: title, model: model)
    }

    var body: some View {
        #if os(tvOS)
        // The chart image goes the same way its CSV siblings do: `ShareLink` is
        // unavailable on tvOS and there is no destination to send a PNG to.
        EmptyView()
        #else
        // An insight the app never decoded has nothing to export in any form —
        // the PNG would be a photograph of the unsupported-insight card.
        // Everything goes rather than offering something useless; those tiles
        // already carry their own "Open in PostHog" link.
        if let export = insight.csvExport {
            // The image entry is the one thing an insight has that a table does
            // not, so it stays here; the three CSV destinations are the shared
            // ones and are not written twice.
            ShareLink(
                item: InsightChartImage(insight: insight),
                preview: SharePreview(title)
            ) {
                Label("Share chart image", systemImage: "photo")
            }
            .accessibilityLabel("Share chart image")

            CSVShareMenuItems(export: export)
        }
        #endif
    }
}

/// Share affordances for a single insight, as a toolbar menu.
struct InsightShareMenu: View {
    let title: String
    let model: InsightRenderModel

    var body: some View {
        #if os(tvOS)
        // As above: the menu's whole contents are unavailable here.
        EmptyView()
        #else
        // `rows` rather than `encode`: this decides whether to draw a button, and
        // the two answer the same question — but `encode` answered it by building
        // the entire file, during `body`, on every layout pass.
        if InsightCSV.rows(model) != nil {
            Menu {
                InsightShareMenuItems(title: title, model: model)
            } label: {
                // The frame is the hit target. This menu's one call site is the
                // insight side panel's hand-drawn header, where nothing supplies
                // a control size the way a toolbar would: measured from the
                // running app on iPad, the accessibility frame was 18.0 × 21.0
                // against a 44 × 44 HIG minimum. Inside the `if` so a model with
                // nothing to export still reserves no space at all.
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Share \(title)")
        }
        #endif
    }
}
