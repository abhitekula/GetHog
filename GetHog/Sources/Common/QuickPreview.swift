import GetHogUI
import SwiftUI

enum QuickPreviewLayout {
    static func factsAxis(for size: DynamicTypeSize) -> Axis {
        size.isAccessibilitySize ? .vertical : .horizontal
    }
}

enum QuickPreviewEnrichment<Value> {
    case idle
    case loading(previous: Value? = nil, loadedAt: Date? = nil)
    case loaded(Value, loadedAt: Date)
    case unavailable
    case stale(Value, loadedAt: Date)

    var value: Value? {
        switch self {
        case .idle, .unavailable:
            nil
        case .loading(let previous, _):
            previous
        case .loaded(let value, _), .stale(let value, _):
            value
        }
    }

    var statusText: String? {
        switch self {
        case .idle, .loaded:
            nil
        case .loading:
            "Loading cached details…"
        case .unavailable:
            "More details unavailable"
        case .stale:
            "Refresh failed"
        }
    }

    func retainingValueAfterFailure() -> Self {
        switch self {
        case .loaded(let value, let loadedAt):
            .stale(value, loadedAt: loadedAt)
        case .loading(let previous?, let loadedAt?):
            .stale(previous, loadedAt: loadedAt)
        case .stale:
            self
        case .idle, .loading, .unavailable:
            .unavailable
        }
    }
}

struct QuickPreviewCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let accessibilitySummary: String
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        accessibilitySummary: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accessibilitySummary = accessibilitySummary
        self.content = content()
    }

    var body: some View {
        Card(accent: Theme.accent) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(
                    title: title,
                    systemImage: systemImage,
                    subtitle: subtitle,
                    showsBrandStitch: true
                )
                content
            }
        }
        .frame(idealWidth: 420, maxWidth: 520, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }
}

extension View {
    @ViewBuilder
    func quickPreview<Preview: View, MenuItems: View>(
        @ViewBuilder preview: () -> Preview,
        @ViewBuilder menuItems: () -> MenuItems
    ) -> some View {
        #if os(iOS) || os(visionOS)
        contextMenu(menuItems: menuItems, preview: preview)
        #elseif os(macOS)
        contextMenu(menuItems: menuItems)
        #else
        self
        #endif
    }
}
