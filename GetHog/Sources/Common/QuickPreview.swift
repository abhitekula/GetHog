import GetHogUI
import SwiftUI

private struct QuickPreviewSourceTraits: Sendable {
    let usesRegularHorizontalLayout: Bool
    let usesCompactVerticalLayout: Bool
}

private struct QuickPreviewSourceTraitsKey: EnvironmentKey {
    static let defaultValue: QuickPreviewSourceTraits? = nil
}

private extension EnvironmentValues {
    var quickPreviewSourceTraits: QuickPreviewSourceTraits? {
        get { self[QuickPreviewSourceTraitsKey.self] }
        set { self[QuickPreviewSourceTraitsKey.self] = newValue }
    }
}

enum QuickPreviewLayout {
    static let idealWidth: CGFloat = 360
    static let maximumWidth: CGFloat = 560

    static func factsAxis(for size: DynamicTypeSize) -> Axis {
        size.isAccessibilitySize ? .vertical : .horizontal
    }

    static func minimumContentHeight(
        usesRegularHorizontalLayout: Bool,
        usesCompactVerticalLayout: Bool,
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat? {
        guard !usesCompactVerticalLayout, !dynamicTypeSize.isAccessibilitySize else {
            return nil
        }
        return usesRegularHorizontalLayout ? 268 : 212
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.quickPreviewSourceTraits) private var sourceTraits
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var usesRegularHorizontalLayout: Bool {
        sourceTraits?.usesRegularHorizontalLayout ?? (horizontalSizeClass == .regular)
    }

    private var usesCompactVerticalLayout: Bool {
        sourceTraits?.usesCompactVerticalLayout ?? (verticalSizeClass == .compact)
    }

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
        Card(padding: Theme.Space.xl, accent: Theme.accent) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                CardHeader(
                    title: title,
                    systemImage: systemImage,
                    subtitle: subtitle,
                    subtitleLineLimit: 2,
                    showsBrandStitch: true
                )
                Divider()
                content
            }
            .frame(
                minHeight: QuickPreviewLayout.minimumContentHeight(
                    usesRegularHorizontalLayout: usesRegularHorizontalLayout,
                    usesCompactVerticalLayout: usesCompactVerticalLayout,
                    dynamicTypeSize: dynamicTypeSize
                ),
                alignment: .topLeading
            )
        }
        .frame(
            idealWidth: QuickPreviewLayout.idealWidth,
            maxWidth: QuickPreviewLayout.maximumWidth,
            alignment: .leading
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }
}

private struct QuickPreviewModifier<Preview: View, MenuItems: View>: ViewModifier {
    let preview: () -> Preview
    let menuItems: () -> MenuItems

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS) || os(visionOS)
        content.contextMenu(
            menuItems: menuItems,
            preview: {
                preview().environment(
                    \.quickPreviewSourceTraits,
                    QuickPreviewSourceTraits(
                        usesRegularHorizontalLayout: horizontalSizeClass == .regular,
                        usesCompactVerticalLayout: verticalSizeClass == .compact
                    )
                )
            }
        )
        #elseif os(macOS)
        content.contextMenu(menuItems: menuItems)
        #else
        content
        #endif
    }
}

extension View {
    func quickPreview<Preview: View, MenuItems: View>(
        @ViewBuilder preview: @escaping () -> Preview,
        @ViewBuilder menuItems: @escaping () -> MenuItems
    ) -> some View {
        modifier(
            QuickPreviewModifier(
                preview: preview,
                menuItems: menuItems
            )
        )
    }
}
