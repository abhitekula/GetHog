import GetHogUI
import SwiftUI

struct BrandMotionValues: Equatable {
    let opacity: Double
    let y: CGFloat
    let scale: CGFloat

    static let settled = BrandMotionValues(opacity: 0, y: 0, scale: 1)

    static func confirmation(reduceMotion: Bool, active: Bool) -> BrandMotionValues {
        guard !reduceMotion, active else { return .settled }
        return BrandMotionValues(opacity: 1, y: -2, scale: 1.04)
    }

    static func illustration(reduceMotion: Bool, appeared: Bool) -> BrandMotionValues {
        if reduceMotion || appeared {
            BrandMotionValues(opacity: 1, y: 0, scale: 1)
        } else {
            BrandMotionValues(opacity: 0, y: 8, scale: 0.98)
        }
    }
}

struct SignalConfirmationLifecycle: Equatable {
    private(set) var active = false
    private(set) var generation = 0

    mutating func activate(reduceMotion: Bool) -> Int? {
        guard !reduceMotion else {
            settleImmediately()
            return nil
        }

        generation += 1
        active = true
        return generation
    }

    mutating func settle(generation: Int) {
        guard generation == self.generation else { return }
        active = false
    }

    mutating func settleImmediately() {
        generation += 1
        active = false
    }
}

private struct SignalConfirmationReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct SignalConfirmationAnimationKey: EnvironmentKey {
    static let defaultValue: Animation? = .easeOut(duration: 0.18)
}

extension EnvironmentValues {
    var signalConfirmationReduceMotionOverride: Bool? {
        get { self[SignalConfirmationReduceMotionOverrideKey.self] }
        set { self[SignalConfirmationReduceMotionOverrideKey.self] = newValue }
    }

    var signalConfirmationAnimation: Animation? {
        get { self[SignalConfirmationAnimationKey.self] }
        set { self[SignalConfirmationAnimationKey.self] = newValue }
    }
}

private struct SignalConfirmationModifier<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.signalConfirmationReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.signalConfirmationAnimation) private var confirmationAnimation
    @State private var lifecycle = SignalConfirmationLifecycle()
    @State private var resetTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        let reduceMotionEnabled = reduceMotionOverride ?? reduceMotion
        let values = BrandMotionValues.confirmation(
            reduceMotion: reduceMotionEnabled,
            active: lifecycle.active
        )
        content.overlay(alignment: .topTrailing) {
            BrandQuillStitch(size: 14)
                .opacity(values.opacity)
                .offset(y: values.y)
                .scaleEffect(values.scale)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .onChange(of: trigger) { _, _ in
            resetTask?.cancel()
            guard !reduceMotionEnabled else {
                lifecycle.settleImmediately()
                return
            }
            var generation: Int?
            withAnimation(confirmationAnimation) {
                generation = lifecycle.activate(reduceMotion: false)
            }
            guard let generation else { return }
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                lifecycle.settle(generation: generation)
            }
        }
        .onChange(of: reduceMotionEnabled) { _, enabled in
            guard enabled else { return }
            resetTask?.cancel()
            lifecycle.settleImmediately()
        }
        .onDisappear {
            resetTask?.cancel()
            lifecycle.settleImmediately()
        }
    }
}

extension View {
    func signalConfirmation<Trigger: Equatable>(trigger: Trigger) -> some View {
        modifier(SignalConfirmationModifier(trigger: trigger))
    }
}

/// A decorative signal that accompanies the app's existing connection state.
/// The real `ProgressView` remains present and owns all loading semantics.
struct BrandConnectingAccent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(color(at: index))
                    .frame(width: 8, height: height(at: index))
                    .rotationEffect(.degrees(rotation(at: index)))
                    .scaleEffect(
                        x: 1,
                        y: reduceMotion || pulsing ? 1 : 0.72,
                        anchor: .bottom
                    )
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.12),
                        value: pulsing
                    )
            }
        }
        .frame(width: 56, height: 30)
        .onChange(of: reduceMotion, initial: true) { _, newValue in
            pulsing = !newValue
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func height(at index: Int) -> CGFloat {
        [18, 24, 30][index]
    }

    private func rotation(at index: Int) -> Double {
        [-14, 0, 10][index]
    }

    private func color(at index: Int) -> Color {
        [Theme.accentWarm, Theme.Ink.tertiary, Theme.accent][index]
    }
}
