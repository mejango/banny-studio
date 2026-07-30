import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

    func testCustomOutfitRegistrationJoinsNormalCatalogResolution() throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        var bytes: [UInt8] = [
            255, 0, 0, 255, 0, 0, 0, 0,
            0, 0, 0, 0, 255, 0, 0, 255,
        ]
        let image = try XCTUnwrap(bytes.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        })
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        XCTAssertTrue(catalog.registerCustomOutfit(
            name: "custom-test",
            label: "Test Jacket",
            slot: OutfitCategory.suitTop.rawValue,
            pngData: data as Data
        ))
        XCTAssertEqual(catalog.outfitSlot("custom-test"), OutfitCategory.suitTop.rawValue)
        XCTAssertNotNil(catalog.outfitImage("custom-test", body: .alien))
        XCTAssertTrue(catalog.outfits(inSlot: OutfitCategory.suitTop.rawValue)
            .contains { $0.name == "custom-test" && $0.label == "Test Jacket" })
        catalog.hideCustomOutfitFromPicker("custom-test")
        XCTAssertFalse(catalog.outfits(inSlot: OutfitCategory.suitTop.rawValue)
            .contains { $0.name == "custom-test" })
        XCTAssertNotNil(catalog.outfitImage("custom-test", body: .alien),
                        "open projects must retain their decoded image")
    }
}
