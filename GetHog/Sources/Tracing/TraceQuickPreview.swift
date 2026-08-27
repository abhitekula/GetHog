import GetHogKit
import GetHogUI
import SwiftUI

struct TraceQuickPreviewPresentation: Equatable {
    let identifier: String
    let operation: String
    let service: String?
    let duration: String
    let status: String
    let spanCount: Int
    let errorCount: Int

    init(trace: TraceGroup) {
        identifier = trace.shortID
        operation = trace.name
        service = trace.root?.serviceName
        duration = trace.formattedDuration
        status = trace.hasError ? "Error" : trace.root?.status.title ?? "Unknown"
        spanCount = trace.spans.count
        errorCount = trace.errorCount
    }

    var spanText: String {
        "\(spanCount) \(spanCount == 1 ? "span" : "spans")"
    }

    var errorText: String {
        "\(errorCount) \(errorCount == 1 ? "error" : "errors")"
    }

    var accessibilitySummary: String {
        var parts = [operation, "Trace \(identifier)"]
        if let service { parts.append("Service \(service)") }
        parts.append("Duration \(duration)")
        parts.append("Status \(status)")
        parts.append(spanText)
        parts.append(errorText)
        return parts.joined(separator: ". ")
    }
}

struct TraceQuickPreview: View {
    let trace: TraceGroup

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: TraceQuickPreviewPresentation {
        TraceQuickPreviewPresentation(trace: trace)
    }

    var body: some View {
        QuickPreviewCard(
            title: presentation.operation,
            systemImage: trace.hasError
                ? "exclamationmark.triangle.fill"
                : "point.3.connected.trianglepath.dotted",
            accessibilitySummary: presentation.accessibilitySummary
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(presentation.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let service = presentation.service {
                    Label(service, systemImage: "server.rack")
                }
                facts
            }
            .font(.caption)
            .foregroundStyle(Theme.Ink.secondary)
        }
        .accessibilityIdentifier("gethog.quick-preview.trace.\(trace.id)")
    }

    private var facts: some View {
        let layout = if QuickPreviewLayout.factsAxis(for: dynamicTypeSize) == .vertical {
            AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s))
        } else {
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Space.m))
        }
        return layout {
            Label(presentation.duration, systemImage: "clock")
            Label(presentation.status, systemImage: "circle.fill")
            Label(presentation.spanText, systemImage: "point.3.connected.trianglepath.dotted")
            Label(presentation.errorText, systemImage: "exclamationmark.triangle")
        }
    }
}
