import GetHogKit
import GetHogUI
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

struct ExpandedReplayView: View {
    let recording: SessionRecording
    let loader: ReplayLoader
    let initialPosition: TimeInterval
    let initialSpeed: Double
    /// Whether playback was running when the user expanded. Full screen is a
    /// bigger seat for the same show — it must not also be the pause button.
    var initialResume = false
    let markers: [SessionReplayMarker]
    /// Reports where the playhead ended up and whether it was playing, so the
    /// inline player can pick up mid-motion exactly where this view left off.
    let onClose: (TimeInterval, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = ReplayPlayerController()
    @State private var archiveCursor: ReplayArchiveDeliveryCursor?
    @State private var didClose = false
    @State private var seekArbiter = ReplaySeekArbiter()
    @State private var didRestoreInitialPosition = false

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
                        .background(Theme.replayStageBackground)
                        .accessibilityRepresentation {
                            Rectangle().accessibilityLabel("Full-screen session replay")
                        }
                }

                PlayerTransportBar(
                    controller: controller,
                    duration: duration,
                    buffered: loader.isComplete ? duration : loader.bufferedSeconds,
                    isComplete: loader.isComplete,
                    markers: markers,
                    positionAccessibilityLabel: "Full-screen playback position",
                    scrubCancellationToken: seekArbiter.sliderCancellationToken,
                    onPreviewSeek: { controller.seek(to: $0, resume: false) },
                    onCoverageRequested: { requestCoverage(for: $0) },
                    onScrubCommitted: { target, resume in
                        commitSliderSeek(to: target, resume: resume)
                    },
                    onScrubBegan: {
                        seekArbiter.sliderBegan(generation: $0)
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
            // The handoff position waits for *this* player to know that much
            // of the recording. It used to ride in through
            // `preparePlaybackForNextReady`, which seeks the instant rrweb
            // boots — and the loader's `bufferedSeconds` is no help either,
            // because that measures what has been *fetched*, not what has been
            // *delivered to this instance*. A goto past the expanded player's
            // own duration does not join the stream mid-way; rrweb runs off
            // the end of what it has and reports `finish`, which is why entry
            // kept landing at the right position, paused. `playerDuration`
            // grows with each appended chunk, so the restore fires the moment
            // the target is actually reachable.
            .onChange(of: controller.isReady, initial: true) { _, _ in
                attemptEntryRestore()
            }
            .onChange(of: controller.playerDuration) { _, _ in
                attemptEntryRestore()
            }
            .onChange(of: loader.archiveDeliveryRevision) { _, _ in
                feedArchive()
            }
            .onChange(of: controller.currentTime) { _, now in
                requestCoverage(for: now)
            }
            .onChange(of: loader.bufferedSeconds) { _, buffered in
                guard case .seek(let target, let resume) = seekArbiter.coverageAdvanced(
                    to: buffered
                ) else { return }
                controller.seek(to: target, resume: resume)
            }
            .onChange(of: loader.isComplete) { _, complete in
                guard complete,
                      case .seek(let target, let resume) = seekArbiter.coverageAdvanced(
                        to: duration
                      )
                else { return }
                controller.seek(to: target, resume: resume)
            }
        }
        .interactiveDismissDisabled()
        #if os(macOS)
        .macReplayKeyboardTransport(controller: controller, duration: duration)
        #endif
    }

    private var duration: TimeInterval {
        max(recording.recordingDuration ?? 0, controller.playerDuration)
    }

    private func feedArchive() {
        guard controller.isDocumentReady else { return }
        if archiveCursor == nil {
            prepareInitialPlayback()
        }
        let delivery = loader.archiveDelivery(after: archiveCursor)
        if delivery.mode == .restart, archiveCursor != nil {
            controller.restartPlayback(
                rebasingPlayheadBy: delivery.playheadAdjustment
            )
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

    private func prepareInitialPlayback() {
        // Speed only. Position and playback intent are restored through
        // `attemptEntryRestore` — see the onChange pair above for why the
        // prepared-playback path cannot carry them.
        controller.preparePlaybackForNextReady(
            position: 0,
            speed: initialSpeed
        )
    }

    /// Seeks to the handoff position once this player can reach it, resuming
    /// if the inline player was playing. Idempotent; called from both the
    /// ready transition and every duration growth until it fires.
    private func attemptEntryRestore() {
        guard controller.isReady, !didRestoreInitialPosition else { return }
        let target = min(max(0, initialPosition), max(0, duration))
        guard controller.playerDuration + 0.25 >= target else { return }
        didRestoreInitialPosition = true
        seek(to: target, resume: initialResume)
        // Belt and braces for the goto's play flag: a no-op when it was
        // honoured, the recovery when it was not.
        if initialResume { controller.play() }
    }

    private func seek(to seconds: TimeInterval, resume: Bool? = nil) {
        let target = min(max(0, seconds), max(0, duration))
        let shouldResume = resume ?? controller.isPlaying
        switch seekArbiter.requestProgrammatic(
            target: target,
            resume: shouldResume,
            buffered: loader.bufferedSeconds,
            isComplete: loader.isComplete
        ) {
        case .waiting:
            requestCoverage(for: target)
            controller.seek(to: max(0, loader.bufferedSeconds - 1), resume: false)
        case .seek:
            controller.seek(to: target, resume: shouldResume)
        }
    }

    private func commitSliderSeek(to target: TimeInterval, resume: Bool) {
        guard case .seek(let target, let resume) = seekArbiter.acceptSliderCommit(
            target: target,
            resume: resume
        ) else { return }
        controller.seek(to: target, resume: resume)
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
                didRestorePosition: controller.didRestorePreparedPlayback,
                currentTime: controller.expansionHandoffPosition
            ),
            // Read before dismissal tears the controller down: if the show was
            // running in here, it keeps running inline. Closing a bigger
            // window is not a pause gesture.
            controller.isPlaying
        )
    }
}
