import AppKit
import GetHogKit
import SwiftUI
import Testing

@testable import GetHog

@MainActor
@Suite("Mac collection surface policy", .serialized)
struct MacCollectionSurfacePolicyTests {

    @Test("sparse collections cap only their wide Mac measure")
    func sparseCollectionMeasureIsAdaptive() async throws {
        let wide = WidthRecorder()
        try await renderedWidth(available: 1_080, recorder: wide)
        #expect(wide.value == 760)

        let narrow = WidthRecorder()
        try await renderedWidth(available: 640, recorder: narrow)
        #expect(narrow.value == 640)
    }

    @Test("Automation empty collections are complete outcomes")
    func automationEmptyCollectionsAreCompleteOutcomes() async throws {
        let store = AutomationStore()
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: DemoTransport()
        )
        await store.load(client: client, projectID: 1)

        #expect(store.count(for: .workflows) == 0)
        #expect(store.errors[.workflows] == nil)

        for section in AutomationSection.allCases {
            let policy = section.emptyPolicy
            #expect(policy.title == "No \(section.title.lowercased())")
            #expect(policy.systemImage == section.systemImage)
            #expect(!policy.message.isEmpty)
        }
    }

    @Test("Experiments empty outcome routes creation to PostHog")
    func experimentsEmptyOutcomeNamesItsManagementPath() {
        let policy = ExperimentsRoot.emptyPolicy

        #expect(policy.title == "No experiments")
        #expect(policy.message.localizedCaseInsensitiveContains("GetHog reads experiments"))
        #expect(policy.actionTitle == "Create in PostHog")
        #expect(ExperimentsRoot.managementPath == "experiments")
    }

    @Test("Early Access empty outcome routes management to PostHog")
    func earlyAccessEmptyOutcomeNamesItsManagementPath() {
        let policy = EarlyAccessRoot.emptyPolicy

        #expect(policy.title == "No early access features")
        #expect(policy.message.localizedCaseInsensitiveContains("GetHog reads early access"))
        #expect(policy.actionTitle == "Manage in PostHog")
        #expect(EarlyAccessRoot.managementPath == "early_access_features")
    }

    @Test("Support keeps education secondary to the empty outcome")
    func supportEmptyInboxKeepsEducationCollapsed() {
        #expect(SupportRoot.emptyPolicy.title == "No support tickets")
        #expect(SupportRoot.emptyPolicy.actionTitle == "Reload")
        #expect(SupportRoot.emptyGuidePolicy.title == "How tickets reach GetHog")
        #expect(!SupportRoot.emptyGuidePolicy.isInitiallyExpanded)
    }

    private func renderedWidth(available: CGFloat, recorder: WidthRecorder) async throws {
        let controller = NSHostingController(
            rootView: WidthProbe(recorder: recorder)
                .sparseCollectionSurface()
                .frame(width: available, height: 80, alignment: .leading)
        )
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(CGSize(width: available, height: 80))
        window.orderBack(nil)
        defer { window.close() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, recorder.value == 0 {
            window.contentView?.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

}

@MainActor
private final class WidthRecorder {
    var value: CGFloat = 0
}

private struct WidthProbe: View {
    let recorder: WidthRecorder

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                recorder.value = $0
            }
    }
}
