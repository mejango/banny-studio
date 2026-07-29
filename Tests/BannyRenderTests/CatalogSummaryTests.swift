import XCTest
import BannyCore
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

    func testWardrobeThumbnailsResolveWithoutLoadingFullRenderAssets() throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let summary = catalog.summary()

        for body in Body.allCases {
            for slot in summary.slots {
                for outfit in slot.outfits {
                    let image = try XCTUnwrap(
                        catalog.outfitThumbnail(outfit.name, body: body),
                        "\(outfit.label) has no \(body.rawValue) thumbnail")
                    XCTAssertLessThanOrEqual(image.width, 400)
                    XCTAssertLessThanOrEqual(image.height, 400)
                }
            }
            for option in summary.eyes {
                XCTAssertNotNil(catalog.eyesThumbnail(
                    option: option, expression: .open, body: body),
                    "\(option) eyes have no \(body.rawValue) thumbnail")
            }
            for option in summary.mouths {
                XCTAssertNotNil(catalog.mouthThumbnail(
                    option: option, state: .closed, body: body),
                    "\(option) mouth has no \(body.rawValue) thumbnail")
            }
        }
    }
}
