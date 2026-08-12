import AppKit
import SwiftUI
import Testing

@testable import GetHog

@MainActor
@Suite("Mac expanded replay window")
struct MacReplayWindowTests {
    @MainActor
    private final class FinishRecorder {
        var count = 0
    }

    @Test("expanded replay uses the native resizable window policy")
    func nativeWindowPolicy() {
        let controller = MacReplayWindowController(title: "Replay — Alex Example") {}
        defer { controller.window.close() }

        #expect(MacReplayWindowMetrics.defaultSize == CGSize(width: 1_100, height: 760))
        #expect(MacReplayWindowMetrics.minimumSize == CGSize(width: 640, height: 480))
        #expect(controller.window.contentRect(forFrameRect: controller.window.frame).size
            == MacReplayWindowMetrics.defaultSize)
        #expect(controller.window.minSize == MacReplayWindowMetrics.minimumSize)
        #expect(controller.window.styleMask.contains(.titled))
        #expect(controller.window.styleMask.contains(.closable))
        #expect(controller.window.styleMask.contains(.miniaturizable))
        #expect(controller.window.styleMask.contains(.resizable))
        #expect(controller.window.styleMask.contains(.fullSizeContentView))
        #expect(controller.window.title.contains("Alex Example"))
        #expect(controller.window.isReleasedWhenClosed == false)
    }

    @Test("all native close notifications finish one ownership lifecycle")
    func nativeCloseFinishesOnce() {
        let recorder = FinishRecorder()
        let controller = MacReplayWindowController(title: "Replay — Alex Example") {
            recorder.count += 1
        }
        defer { controller.window.close() }

        controller.finishOnce()
        controller.finishOnce()
        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: controller.window)
        )

        #expect(recorder.count == 1)
    }

    @Test("toolbar and disappearance finish one replay handoff")
    func replayHandoffFinishesOnce() {
        let recorder = FinishRecorder()
        var didFinish = false

        ExpandedReplayHandoff.finishOnce(didFinish: &didFinish) {
            recorder.count += 1
        }
        ExpandedReplayHandoff.finishOnce(didFinish: &didFinish) {
            recorder.count += 1
        }

        #expect(didFinish)
        #expect(recorder.count == 1)
    }

    @Test("hosting content keeps one window at the exact default content size")
    func presentationKeepsOneDefaultSizedWindow() {
        let controller = MacReplayWindowController(title: "Replay — Alex Example") {}
        let ownedWindow = controller.window
        defer { ownedWindow.close() }

        controller.present(Text("Expanded replay"))

        #expect(controller.window === ownedWindow)
        #expect(controller.window.contentViewController is NSHostingController<Text>)
        #expect(
            controller.window.contentRect(forFrameRect: controller.window.frame).size
                == MacReplayWindowMetrics.defaultSize
        )
        #expect(
            controller.window.frame.size
                == controller.window.frameRect(
                    forContentRect: NSRect(origin: .zero, size: MacReplayWindowMetrics.defaultSize)
                ).size
        )
    }
}
