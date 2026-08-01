import Combine
import SwiftUI
import Testing
import UIKit
@testable import GetHog

@Suite("Brand motion")
@MainActor
struct BrandMotionTests {
    @Test("Reduced motion always uses the settled illustration values")
    func reducedMotionSettlesImmediately() {
        let values = BrandMotionValues.illustration(reduceMotion: true, appeared: false)

        #expect(values.opacity == 1)
        #expect(values.y == 0)
        #expect(values.scale == 1)
    }

    @Test("Standard motion moves from a subtle entrance to settled values")
    func standardMotionHasBoundedEntrance() {
        let initial = BrandMotionValues.illustration(reduceMotion: false, appeared: false)
        let final = BrandMotionValues.illustration(reduceMotion: false, appeared: true)

        #expect(initial.opacity == 0)
        #expect(initial.y == 8)
        #expect(initial.scale == 0.98)
        #expect(final.opacity == 1)
        #expect(final.y == 0)
        #expect(final.scale == 1)
    }

    @Test("Reduced motion never exposes a confirmation transition")
    func reducedConfirmationSettles() {
        #expect(BrandMotionValues.confirmation(reduceMotion: true, active: true) == .settled)
        #expect(BrandMotionValues.confirmation(reduceMotion: true, active: false) == .settled)
    }

    @Test("Standard confirmation changes only opacity, offset, and scale")
    func standardConfirmationIsBounded() {
        let active = BrandMotionValues.confirmation(reduceMotion: false, active: true)
        #expect(active.opacity == 1)
        #expect(active.y == -2)
        #expect(active.scale == 1.04)
        #expect(BrandMotionValues.confirmation(reduceMotion: false, active: false) == .settled)
    }

    @Test("Confirmation triggers activate only when Reduce Motion is disabled")
    func triggerRespectsReduceMotion() {
        var lifecycle = SignalConfirmationLifecycle()

        #expect(lifecycle.activate(reduceMotion: true) == nil)
        #expect(!lifecycle.active)
        #expect(lifecycle.activate(reduceMotion: false) == 2)
        #expect(lifecycle.active)
    }

    @Test("A replacement trigger invalidates the prior timeout")
    func replacementTriggerInvalidatesPriorTimeout() {
        var lifecycle = SignalConfirmationLifecycle()
        let firstGeneration = lifecycle.activate(reduceMotion: false)
        let secondGeneration = lifecycle.activate(reduceMotion: false)

        #expect(firstGeneration == 1)
        #expect(secondGeneration == 2)
        lifecycle.settle(generation: firstGeneration ?? 0)
        #expect(lifecycle.active)
    }

    @Test("Only the current confirmation timeout can settle the overlay")
    func currentTimeoutSettlesOverlay() {
        var lifecycle = SignalConfirmationLifecycle()
        _ = lifecycle.activate(reduceMotion: false)
        let currentGeneration = lifecycle.activate(reduceMotion: false)

        lifecycle.settle(generation: currentGeneration ?? 0)
        #expect(!lifecycle.active)
    }

    @Test("Enabling Reduce Motion immediately invalidates and settles confirmation")
    func reduceMotionInvalidatesActiveConfirmation() {
        var lifecycle = SignalConfirmationLifecycle()
        let activeGeneration = lifecycle.activate(reduceMotion: false)

        lifecycle.settleImmediately()
        #expect(!lifecycle.active)
        lifecycle.settle(generation: activeGeneration ?? 0)
        #expect(!lifecycle.active)
    }

    @Test("Confirmation modifier settles once and cancels stale visual state")
    func confirmationModifierLifecycleRenders() async throws {
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        let model = SignalConfirmationHarnessModel()
        let host = UIHostingController(rootView: SignalConfirmationHarness(model: model))
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 120)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        await waitForRendering()
        let baseline = try #require(snapshot(of: host.view))

        model.trigger += 1
        await waitForRendering()
        #expect(try #require(snapshot(of: host.view)) != baseline)

        model.reduceMotion = true
        await waitForRendering()
        #expect(try #require(snapshot(of: host.view)) == baseline)
        model.reduceMotion = false
        await waitForRendering(for: 0.27)
        #expect(try #require(snapshot(of: host.view)) == baseline)

        model.trigger += 1
        await waitForRendering()
        #expect(try #require(snapshot(of: host.view)) != baseline)
        await waitForRendering(for: 0.27)
        #expect(try #require(snapshot(of: host.view)) == baseline)
        await waitForRendering(for: 0.04)
        #expect(try #require(snapshot(of: host.view)) == baseline)

        model.trigger += 1
        await waitForRendering()
        await waitForRendering(for: 0.12)
        model.trigger += 1
        await waitForRendering()
        await waitForRendering(for: 0.13)
        #expect(try #require(snapshot(of: host.view)) != baseline)
        await waitForRendering(for: 0.14)
        #expect(try #require(snapshot(of: host.view)) == baseline)
    }

    private func waitForRendering(for interval: TimeInterval = 0.03) async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(Int(interval * 1_000)))
        await Task.yield()
    }

    private func snapshot(of view: UIView) -> Data? {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.pngData { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

}

@MainActor
private final class SignalConfirmationHarnessModel: ObservableObject {
    @Published var trigger = 0
    @Published var reduceMotion = false
}

private struct SignalConfirmationHarness: View {
    @ObservedObject var model: SignalConfirmationHarnessModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.pageBackground)
            Text("Summary")
                .font(.headline)
                .foregroundStyle(Theme.Ink.secondary)
        }
        .frame(width: 240, height: 120)
        .signalConfirmation(trigger: model.trigger)
        .environment(\.signalConfirmationReduceMotionOverride, model.reduceMotion)
    }
}
