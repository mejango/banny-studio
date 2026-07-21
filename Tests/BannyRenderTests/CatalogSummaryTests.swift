import XCTest
@testable import BannyRender

final class CatalogSummaryTests: XCTestCase {
    static let assetsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets")

    func testSummaryListsBodiesAndOutfitsAndRoundTripsJSON() throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let summary = catalog.summary()
        XCTAssertTrue(summary.bodies.contains("orange"))
        XCTAssertFalse(summary.slots.isEmpty)
        for slot in summary.slots {
            XCTAssertFalse(slot.outfits.isEmpty, "slot \(slot.slot) has no outfits")
        }
        XCTAssertFalse(summary.eyes.isEmpty)
        XCTAssertFalse(summary.mouths.isEmpty)

        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(AssetCatalog.Summary.self, from: data)
        XCTAssertEqual(decoded.bodies, summary.bodies)
    }
}
