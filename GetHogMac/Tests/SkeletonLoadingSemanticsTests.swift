import AppKit
import SwiftUI
import Testing

@testable import GetHog

/// The shared skeleton is a visual placeholder, not placeholder information.
///
/// These tests pin the pure spoken/visible policy and mount the real modifier
/// offscreen to prove the named status does not change geometry. A sandboxed
/// Mac host test cannot safely open a compositor window; integrated live
/// acceptance owns the final visible-copy and VoiceOver observation.
@MainActor
@Suite("Skeleton loading semantics", .serialized)
struct SkeletonLoadingSemanticsTests {

    @Test("loading policy resolves one generic or named outcome")
    func loadingPolicyResolvesGenericAndNamedOutcomes() {
        let generic = SkeletonLoadingPresentation(label: nil)
        #expect(generic.accessibilityLabel == "Loading")
        #expect(!generic.showsVisibleStatus)

        let named = SkeletonLoadingPresentation(label: WarehouseRoot.loadingLabel)
        #expect(named.accessibilityLabel == "Loading warehouse…")
        #expect(named.showsVisibleStatus)
    }

    @Test("the loading overlay preserves the placeholder geometry")
    func loadingOverlayPreservesGeometry() {
        let regular = CGSize(width: 360, height: 180)
        let unloaded = measuredSize(proposal: regular, loading: false)
        let loading = measuredSize(proposal: regular, loading: true)
        #expect(unloaded == regular)
        #expect(loading == unloaded)

        let compact = CGSize(width: 12, height: 12)
        let compactUnloaded = measuredSize(proposal: compact, loading: false)
        let compactLoading = measuredSize(proposal: compact, loading: true)
        #expect(compactUnloaded == compact)
        #expect(compactLoading == compactUnloaded)
    }

    @Test("warehouse empty and failed outcomes remain different contracts")
    func warehouseTerminalOutcomesRemainDistinct() {
        let empty = WarehouseRoot.emptyPolicy
        let failure = WarehouseRoot.failurePolicy(message: "Synthetic warehouse outage")

        #expect(empty.title == "Nothing in the warehouse")
        #expect(empty.actionTitle == nil)
        #expect(failure.title == "Couldn't load the warehouse")
        #expect(failure.message == "Synthetic warehouse outage")
        #expect(failure.actionTitle == "Try again")
        #expect(empty != failure)
    }

    /// `fittingSize` asks SwiftUI's real layout engine without ordering an
    /// AppKit window. That matters in the guest's sandbox: window-server/Core
    /// Animation commits from a host test can crash after the assertion has
    /// already measured the correct size.
    private func measuredSize(proposal: CGSize, loading: Bool) -> CGSize {
        let hostingView = NSHostingView(
            rootView: AnyView(
                Color.clear
                    .frame(width: proposal.width, height: proposal.height)
                    .skeleton(loading, label: WarehouseRoot.loadingLabel)
            )
        )
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
    }

}
