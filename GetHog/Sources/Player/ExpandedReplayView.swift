import GetHogKit
import SwiftUI

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
    @State private var archiveCursor = 0
    @State private var didRestorePosition = false
    @State private var didClose = false

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
                    buffered: loader.bufferedSeconds,
                    markers: markers,
                    positionAccessibilityLabel: "Full-screen playback position",
                    onScrubCommitted: { controller.seek(to: $0) }
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
            .onChange(of: loader.archivedEventCount) { _, _ in
                feedArchive()
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
        guard controller.isDocumentReady,
              archiveCursor < loader.archivedEvents.count
        else { return }
        let events = Array(loader.archivedEvents[archiveCursor...])
        archiveCursor = loader.archivedEvents.count
        controller.submit(events: events, reduceMotion: reduceMotion, colorScheme: colorScheme)
    }

    private func close() {
        finishOnce()
        dismiss()
    }

    private func finishOnce() {
        guard !didClose else { return }
        didClose = true
        onClose(controller.currentTime)
    }
}
