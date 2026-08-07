import Testing

@testable import GetHog

/// Copy that sits beside device-owner authentication must name what a Vision
/// Pro can actually offer. The authentication reason itself stays neutral: the
/// system supplies the Optic ID or passcode framing around it.
@Suite("Vision authentication copy")
struct VisionGateCopyTests {

    @Test("the key footer names Optic ID, never phone or Mac sensors")
    func keyFooterNamesVisionBiometry() {
        #expect(SettingsAPIKeySection.keyStorageFooter.contains("Optic ID"))
        #expect(!SettingsAPIKeySection.keyStorageFooter.contains("Face ID"))
        #expect(!SettingsAPIKeySection.keyStorageFooter.contains("Touch ID"))
    }

    @Test("the flag gate reason stays biometry-neutral")
    func gateReasonStaysNeutral() {
        #expect(
            BiometricGate.reason
                == "Confirm you want to change a live feature flag"
        )
    }
}
