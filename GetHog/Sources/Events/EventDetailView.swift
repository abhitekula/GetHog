import GetHogKit
import SwiftUI

struct EventDetailView: View {
    let event: EventRow

    var body: some View {
        List {
            Section("Event") {
                LabeledContent("Name") {
                    Text(event.event).font(.body.monospaced())
                }
                if let ts = event.timestamp {
                    LabeledContent("Timestamp") {
                        Text(ts, format: .dateTime.year().month().day().hour().minute().second())
                            .monospacedDigit()
                    }
                }
                if let distinctID = event.distinctID {
                    LabeledContent("Person") {
                        Text(distinctID).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let url = event.currentURL {
                    LabeledContent("URL") {
                        Text(url).font(.caption).textSelection(.enabled)
                    }
                }
            }

            if let properties = event.properties, case .object(let dict) = properties {
                Section("Properties (\(dict.count))") {
                    ForEach(dict.keys.sorted(), id: \.self) { key in
                        PropertyRow(key: key, value: dict[key] ?? .null)
                    }
                }
            }
        }
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
