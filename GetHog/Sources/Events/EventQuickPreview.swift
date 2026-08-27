import GetHogKit
import GetHogUI
import SwiftUI

struct EventQuickPreviewPresentation: Equatable {
    struct Property: Equatable {
        let key: String
        let value: String
    }

    let event: String
    let timestamp: Date
    let distinctID: String
    let currentURL: String?
    let properties: [Property]

    init(row: EventRow) {
        event = row.event
        timestamp = row.timestamp ?? .distantPast
        distinctID = row.distinctID ?? "Unknown person"
        currentURL = row.currentURL

        let headerValues = Set(
            [row.event, row.distinctID, row.currentURL, row.timestamp?.ISO8601Format()]
                .compactMap { $0 }
        )
        properties = Self.properties(from: row.properties, headerValues: headerValues)
    }

    var accessibilitySummary: String {
        var parts = [
            Self.sentence(event),
            "Timestamp \(timestamp.ISO8601Format()).",
            "Person \(distinctID).",
        ]
        if let currentURL {
            parts.append("URL \(currentURL).")
        }
        parts.append(contentsOf: properties.map { Self.sentence("\($0.key), \($0.value)") })
        return parts.joined(separator: " ")
    }

    private static func properties(
        from value: JSONValue?,
        headerValues: Set<String>
    ) -> [Property] {
        guard case .object(let dictionary) = value else { return [] }
        return dictionary.keys.sorted().compactMap { key in
            guard !headerKeys.contains(key) else { return nil }
            let displayValue = display(dictionary[key] ?? .null)
            guard !headerValues.contains(displayValue) else { return nil }
            return Property(key: key, value: displayValue)
        }
        .prefix(4)
        .map { $0 }
    }

    private static let headerKeys: Set<String> = [
        "event",
        "timestamp",
        "distinct_id",
        "$current_url",
        "properties.$current_url",
    ]

    private static func display(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let value): String(value)
        case .string(let value): value
        case .number(let value): value == value.rounded() ? String(Int(value)) : String(value)
        case .array(let values): "[\(values.count) items]"
        case .object(let values): "{\(values.count) fields}"
        }
    }

    private static func sentence(_ value: String) -> String {
        guard let last = value.last, !".!?".contains(last) else { return value }
        return value + "."
    }
}

struct EventQuickPreview: View {
    let row: EventRow

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: EventQuickPreviewPresentation {
        EventQuickPreviewPresentation(row: row)
    }

    var body: some View {
        QuickPreviewCard(
            title: presentation.event,
            systemImage: EventAppearance.glyph(for: presentation.event),
            accessibilitySummary: presentation.accessibilitySummary
        ) {
            facts
            propertyList
        }
        .accessibilityIdentifier("gethog.quick-preview.event.\(row.id)")
    }

    private var facts: some View {
        let layout = if QuickPreviewLayout.factsAxis(for: dynamicTypeSize) == .vertical {
            AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s))
        } else {
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Space.m))
        }
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(presentation.timestamp.ISO8601Format(), systemImage: "clock")
            layout {
                Label(presentation.distinctID, systemImage: "person.crop.circle")
                if let currentURL = presentation.currentURL {
                    Label(currentURL, systemImage: "link")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.Ink.secondary)
        }
        .font(.caption.monospaced())
    }

    @ViewBuilder
    private var propertyList: some View {
        if !presentation.properties.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(presentation.properties, id: \.key) { property in
                    LabeledContent(property.key) {
                        Text(property.value)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.Ink.secondary)
                            .lineLimit(2)
                    }
                    .font(.caption)
                }
            }
        }
    }
}
