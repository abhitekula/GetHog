import GetHogKit
import SwiftUI

struct EventDetailView: View {
    let event: EventRow

    var body: some View {
        List {
            Section {
                field("Name", glyph: "bolt.fill", value: event.event)
                if let ts = event.timestamp {
                    field(
                        "Timestamp",
                        glyph: "clock",
                        value: ts.formatted(.dateTime.year().month().day().hour().minute().second())
                    )
                }
                if let distinctID = event.distinctID {
                    field("Person", glyph: "person.crop.circle", value: distinctID)
                }
                if let url = event.currentURL {
                    field("URL", glyph: "link", value: url)
                }
            } header: {
                SectionLabel(text: "Event", systemImage: "bolt")
            }

            if let properties = event.properties, case .object(let dict) = properties {
                Section {
                    ForEach(dict.keys.sorted(), id: \.self) { key in
                        PropertyRow(key: key, value: dict[key] ?? .null)
                            .listRowBackground(
                                Theme.cardBackground
                                    .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                    .padding(.vertical, 1)
                            )
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    SectionLabel(text: "Properties (\(dict.count))", systemImage: "tag")
                }
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .navigationTitle(event.event)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = jsonRepresentation
                } label: {
                    Label("Copy as JSON", systemImage: "doc.on.doc")
                }
            }
        }
    }

    /// One field of the event's header, as a row rather than a label/value pair.
    private func field(_ label: String, glyph: String, value: String) -> some View {
        DataRow(
            glyph: glyph,
            title: label,
            subtitle: value,
            // Every value in this section is an identifier or a fixed-width
            // figure — event name, timestamp, distinct id, URL — so all four
            // stay monospaced rather than only the two that used to be.
            isSubtitleMonospaced: true,
            accessory: .none
        )
        // Kept from the rows this replaced: the distinct id and the URL are the
        // two things people pull out of an event by hand, and selection is the
        // only way to get at them short of copying the whole JSON payload.
        .textSelection(.enabled)
        .listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
    }

    private var jsonRepresentation: String {
        var payload: [String: Any] = ["event": event.event]
        if let ts = event.timestamp { payload["timestamp"] = ts.ISO8601Format() }
        if let distinctID = event.distinctID { payload["distinct_id"] = distinctID }
        if let properties = event.properties,
           let data = try? JSONEncoder().encode(properties),
           let decoded = try? JSONSerialization.jsonObject(with: data) {
            payload["properties"] = decoded
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return event.event }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One property. Nested objects and arrays expand rather than being flattened
/// into an unreadable string.
struct PropertyRow: View {
    let key: String
    let value: JSONValue

    var body: some View {
        switch value {
        case .object(let dict) where !dict.isEmpty:
            DisclosureGroup {
                ForEach(dict.keys.sorted(), id: \.self) { child in
                    PropertyRow(key: child, value: dict[child] ?? .null)
                }
            } label: {
                keyLabel(detail: "\(dict.count) fields")
            }

        case .array(let items) where !items.isEmpty:
            DisclosureGroup {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    PropertyRow(key: "[\(index)]", value: item)
                }
            } label: {
                keyLabel(detail: "\(items.count) items")
            }

        default:
            LabeledContent {
                Text(displayValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            } label: {
                Text(key).font(.caption).lineLimit(1)
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = displayValue
                } label: {
                    Label("Copy value", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private func keyLabel(detail: String) -> some View {
        HStack {
            Text(key).font(.caption)
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var displayValue: String {
        switch value {
        case .null: "null"
        case .bool(let b): String(b)
        case .string(let s): s
        case .number(let d): d == d.rounded() ? String(Int(d)) : String(d)
        case .array(let a): a.isEmpty ? "[]" : "[\(a.count)]"
        case .object(let o): o.isEmpty ? "{}" : "{\(o.count)}"
        }
    }
}
