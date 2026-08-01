import Testing
import UIKit

@Suite("Brand mark asset")
@MainActor
struct BrandMarkAssetTests {
    @Test("The app bundle exposes the in-app brand mark")
    func brandMarkLoads() throws {
        let image = try #require(UIImage(named: "BrandMark"))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}
