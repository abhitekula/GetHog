import GetHogKit
import GetHogUI
import SwiftUI

struct FlagQuickPreviewPresentation: Equatable {
    let key: String
    let name: String?
    let status: String
    let rollout: String
    let conditionCount: Int
    let variantCount: Int
    let isMultivariate: Bool

    init(flag: FeatureFlag) {
        key = flag.key
        name = flag.name
        status = flag.archived ? "Archived" : flag.active ? "Enabled" : "Disabled"
        rollout = flag.rolloutPercentage.map { "\(FlagFormat.percent($0)) rollout" }
            ?? "No rollout percentage"
        conditionCount = flag.conditionGroups.count
        variantCount = flag.variants.count
        isMultivariate = flag.isMultivariate
    }

    var conditionSetText: String {
        "\(conditionCount) condition \(conditionCount == 1 ? "set" : "sets")"
    }

    var variantText: String {
        "\(variantCount) \(variantCount == 1 ? "variant" : "variants")"
    }

    var multivariateText: String {
        isMultivariate ? "Multivariate" : "Not multivariate"
    }

    var accessibilitySummary: String {
        var parts = [name ?? key]
        if name != nil { parts.append("Key \(key)") }
        parts.append("Status \(status)")
        parts.append(rollout)
        parts.append(conditionSetText)
        parts.append(variantText)
        parts.append(multivariateText)
        return parts.joined(separator: ". ")
    }
}

struct FlagQuickPreview: View {
    let flag: FeatureFlag

    private var presentation: FlagQuickPreviewPresentation {
        FlagQuickPreviewPresentation(flag: flag)
    }

    var body: some View {
        QuickPreviewCard(
            title: presentation.name ?? presentation.key,
            subtitle: presentation.name == nil ? nil : presentation.key,
            systemImage: flag.isMultivariate ? "arrow.triangle.branch" : "flag.fill",
            accessibilitySummary: presentation.accessibilitySummary
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label(presentation.status, systemImage: "flag")
                Label(presentation.rollout, systemImage: "percent")
                Label(presentation.conditionSetText, systemImage: "line.3.horizontal.decrease.circle")
                Label(presentation.variantText, systemImage: "square.stack.3d.up")
                Label(
                    presentation.multivariateText,
                    systemImage: presentation.isMultivariate ? "arrow.triangle.branch" : "flag"
                )
            }
            .font(.caption)
            .foregroundStyle(Theme.Ink.secondary)
        }
        .accessibilityIdentifier("gethog.quick-preview.flag.\(flag.id)")
    }
}
