import GetHogKit
import SwiftUI

enum ExpandedReplayHandoff {
    static func dismissalPosition(
        initialPosition: TimeInterval,
        didRestorePosition: Bool,
        currentTime: TimeInterval
    ) -> TimeInterval {
        didRestorePosition ? currentTime : initialPosition
    }
}

@MainActor
enum ExpandedReplayCoverage {
    static func target(after playhead: TimeInterval) -> TimeInterval {
        max(0, playhead) + ReplayLoader.prefetchLead
    }
}

private struct DeferredReplaySeek {
    let target: TimeInterval
    let resume: Bool
}

struct ExpandedReplayView: View {
    let recording: SessionRecording
    let loader: ReplayLoader
    let initialPosition: TimeInterval
    let initialSpeed: Double
    let markers: [SessionReplayMarker]
    let onClose: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = ReplayPlayerController()
    @State private var archiveCursor: ReplayArchiveDeliveryCursor?
    @State private var didRestorePosition = false
    @State private var didClose = false
    @State private var pendingSeek: DeferredReplaySeek?

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.m) {
                if let failure = controller.failure {
                    SectionEmptyState(
                        text: "Couldn't display the expanded replay.",
                        systemImage: "play.slash",
                        detail: failure
                    )
                    .padding(Theme.Space.l)
                } else {
                    WKWebViewRepresentable(controller: controller)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .accessibilityRepresentation {
                            Rectangle().accessibilityLabel("Full-screen session replay")
                        }
                }

                PlayerTransportBar(
                    controller: controller,
                    duration: duration,
                    buffered: loader.isComplete ? duration : loader.bufferedSeconds,
                    markers: markers,
                    positionAccessibilityLabel: "Full-screen playback position",
                    onPreviewSeek: { controller.seek(to: $0, resume: false) },
                    onCoverageRequested: { requestCoverage(for: $0) },
                    onScrubCommitted: { target, resume in
                        seek(to: target, resume: resume)
                    },
                    onMarkerSeek: { target in
                        seek(to: target, resume: controller.isPlaying)
                    }
                )
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.cardBackground)
            }
            .background(Theme.cardBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) {
                        Label("Close", systemImage: "xmark")
                            .minimumHitTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close full-screen replay")
                }
            }
            .onChange(of: controller.isDocumentReady, initial: true) { _, _ in
                feedArchive()
            }
            .onChange(of: loader.archiveDeliveryRevision) { _, _ in
                feedArchive()
            }
            .onChange(of: controller.currentTime) { _, now in
                requestCoverage(for: now)
            }
            .onChange(of: loader.bufferedSeconds) { _, buffered in
                guard let pending = pendingSeek, buffered >= pending.target else { return }
                pendingSeek = nil
                controller.seek(to: pending.target, resume: pending.resume)
            }
            .onChange(of: controller.isReady) { _, ready in
                guard ready, !didRestorePosition else { return }
                didRestorePosition = true
                controller.setSpeed(initialSpeed)
                controller.seek(to: initialPosition, resume: false)
            }
        }
        .interactiveDismissDisabled()
        .onDisappear { finishOnce() }
    }

    private var duration: TimeInterval {
        max(recording.recordingDuration ?? 0, controller.playerDuration)
    }

    private func feedArchive() {
        guard controller.isDocumentReady else { return }
        let delivery = loader.archiveDelivery(after: archiveCursor)
        if delivery.mode == .restart, archiveCursor != nil {
            controller.restartPlayback()
            didRestorePosition = false
        }
        guard !delivery.events.isEmpty else {
            archiveCursor = delivery.cursor
            return
        }
        guard controller.submit(
            events: delivery.events,
            reduceMotion: reduceMotion,
            colorScheme: colorScheme
        ) else { return }
        archiveCursor = delivery.cursor
    }

    private func requestCoverage(for playhead: TimeInterval) {
        loader.ensureCoverage(upTo: ExpandedReplayCoverage.target(after: playhead))
    }

    private func seek(to seconds: TimeInterval, resume: Bool? = nil) {
        let target = max(0, seconds)
        let shouldResume = resume ?? controller.isPlaying
        if target > loader.bufferedSeconds, !loader.isComplete {
            pendingSeek = DeferredReplaySeek(target: target, resume: shouldResume)
            requestCoverage(for: target)
            controller.seek(to: max(0, loader.bufferedSeconds - 1), resume: false)
        } else {
            pendingSeek = nil
            controller.seek(to: target, resume: shouldResume)
        }
    }

    private func close() {
        finishOnce()
        dismiss()
    }

    private func finishOnce() {
        guard !didClose else { return }
        didClose = true
        onClose(
            ExpandedReplayHandoff.dismissalPosition(
                initialPosition: initialPosition,
                didRestorePosition: didRestorePosition,
                currentTime: controller.currentTime
            )
        )
    }
}
