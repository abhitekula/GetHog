import Testing

@testable import GetHog

@MainActor
@Suite("Mac presentation metrics")
struct MacPresentationMetricsTests {

    @Test("Mac controls and list cards use desktop metrics")
    func desktopMetrics() {
        #expect(PlatformPresentationMetrics.minimumInteractiveLength == 28)
        #expect(PlatformPresentationMetrics.listCardVerticalInset == 3)
        #expect(PlatformPresentationMetrics.listCardVerticalInset * 2 == 6)
        #expect(PlatformPresentationMetrics.listCardVerticalInset * 2 >= 4)
        #expect(DashboardTemplatesRoot.minimumCardWidth == 340)
    }
}
