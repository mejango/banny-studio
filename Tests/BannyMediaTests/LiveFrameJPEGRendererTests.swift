import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import BannyCore
import BannyRender
@testable import BannyMedia

final class LiveFrameJPEGRendererTests: XCTestCase {
    private static let assetsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets")

    func testRendersFittedP720JPEGWithinConfiguredLimit() async throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let document = ShowDocument.starter(characterCount: 1)
        let renderer = LiveFrameJPEGRenderer(
            documentAssets: document.assets,
            assetURLs: [:],
            catalog: catalog,
            maximumBytes: 500_000)

        let data = try await renderer.render(document: document, at: 0)

        XCTAssertLessThanOrEqual(data.count, 500_000)
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(image?.width, 1_280)
        XCTAssertEqual(image?.height, 720)
    }

    func testKeepsStableMediaBankAcrossForwardAndBackwardFrames() async throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-frame-\(UUID().uuidString).gif")
        try makeTwoFrameGIF().write(to: mediaURL)
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let asset = Asset(
            id: "background", name: "Loop", kind: .image,
            file: mediaURL.lastPathComponent)
        var stage = SceneState()
        stage.backgroundTracks = [BackgroundTrack(
            id: "scenes", name: "Scenes",
            cues: [BackgroundCue(
                id: "loop", assetID: asset.id, start: 0, dur: 10)])]
        let document = ShowDocument(stage: stage, assets: [asset])
        let renderer = LiveFrameJPEGRenderer(
            documentAssets: document.assets,
            assetURLs: [asset.id: mediaURL],
            catalog: catalog)

        let first = try await renderer.render(document: document, at: 0.05)
        // Once sampled, the room renderer owns the decoded media state. Removing
        // the fixture makes this test fail if render() silently creates a fresh
        // AssetSampler on every request.
        try FileManager.default.removeItem(at: mediaURL)
        let forward = try await renderer.render(document: document, at: 0.25)
        let backward = try await renderer.render(document: document, at: 0.05)

        XCTAssertNotEqual(centerRGB(first), centerRGB(forward))
        XCTAssertEqual(centerRGB(first), centerRGB(backward))
    }

    func testRejectsDocumentWhoseAssetBankChanged() async throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let document = ShowDocument.starter(characterCount: 0)
        let renderer = LiveFrameJPEGRenderer(
            documentAssets: document.assets,
            assetURLs: [:],
            catalog: catalog)
        var changed = document
        changed.assets.append(Asset(id: "later", name: "Later", kind: .image, file: "later.png"))

        do {
            _ = try await renderer.render(document: changed, at: 0)
            XCTFail("Expected a stable media-bank error")
        } catch let error as LiveFrameJPEGRenderer.RenderError {
            XCTAssertEqual(error, .documentAssetsChanged)
        }
    }

    func testReportsWhenConfiguredByteLimitCannotBeMet() async throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let document = ShowDocument.starter(characterCount: 0)
        let renderer = LiveFrameJPEGRenderer(
            documentAssets: document.assets,
            assetURLs: [:],
            catalog: catalog,
            maximumBytes: 1)

        do {
            _ = try await renderer.render(document: document, at: 0)
            XCTFail("Expected the one-byte JPEG limit to fail")
        } catch let error as LiveFrameJPEGRenderer.RenderError {
            XCTAssertEqual(error, .imageTooLarge(maximumBytes: 1))
        }
    }

    func testSpriteCacheHasExplicitTenCharacterRoomBudget() {
        XCTAssertEqual(LiveFrameJPEGRenderer.spriteCachePixelSize, 640)
        XCTAssertEqual(LiveFrameJPEGRenderer.spriteCacheCapacity, 24)
        XCTAssertEqual(
            LiveFrameJPEGRenderer.approximateSpriteCacheByteBudget,
            640 * 640 * 4 * 24)
        XCTAssertLessThanOrEqual(
            LiveFrameJPEGRenderer.approximateSpriteCacheByteBudget,
            40 * 1_024 * 1_024,
            "A room's flattened RGBA character cache should stay near 37.5 MiB")
    }

    func testLateTenCharacterRoomReusesPositionTimelines() async throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        var document = ShowDocument.starter(characterCount: 10)
        for index in document.stage.characters.indices {
            document.stage.characters[index].events = [
                .key(
                    t: 0,
                    code: index.isMultiple(of: 2) ? .arrowRight : .arrowLeft,
                    down: true),
            ]
            // Distinct inputs ensure all ten performers own a timeline and
            // avoid accidentally hitting a timeline built by another test.
            document.stage.characters[index].speed = 347.125 + Double(index) / 1_000
        }
        let renderer = LiveFrameJPEGRenderer(
            documentAssets: document.assets,
            assetURLs: [:],
            catalog: catalog)

        // Populate the exact-input position timelines and appearance cache.
        _ = try await renderer.render(document: document, at: 3_598.5)

        let clock = ContinuousClock()
        let warmStart = clock.now
        _ = try await renderer.render(document: document, at: 3_598.625)
        let warmDuration = warmStart.duration(to: clock.now)

        // Changing every position source forces ten cold hour-long timelines,
        // but intentionally leaves sprite appearance keys unchanged.
        var coldDocument = document
        for index in coldDocument.stage.characters.indices {
            coldDocument.stage.characters[index].speed += 0.25
        }
        let coldStart = clock.now
        _ = try await renderer.render(document: coldDocument, at: 3_598.75)
        let coldDuration = coldStart.duration(to: clock.now)

        let warmSeconds = seconds(warmDuration)
        let coldSeconds = seconds(coldDuration)
        XCTAssertLessThan(
            warmSeconds * 2,
            coldSeconds,
            "A cached late frame (\(warmSeconds)s) should be over 2x faster than rebuilding ten hour-long timelines (\(coldSeconds)s)")
    }

    func testPreCancelledRenderStopsCooperatively() async throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let document = ShowDocument.starter(characterCount: 10)
        let renderer = LiveFrameJPEGRenderer(
            documentAssets: document.assets,
            assetURLs: [:],
            catalog: catalog)
        let task = Task {
            // Ensure cancellation is already observable when the actor method
            // begins, independent of task scheduling order in the test runner.
            while !Task.isCancelled { await Task.yield() }
            return try await renderer.render(document: document, at: 3_599)
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected a cancelled live render to stop")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func seconds(_ duration: ContinuousClock.Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func makeTwoFrameGIF() throws -> Data {
        func frame(_ color: CGColor) -> CGImage {
            let context = CGContext(
                data: nil, width: 8, height: 8,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return context.makeImage()!
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, 2, nil)
        else { throw LiveFrameJPEGRenderer.RenderError.encodeFailed }
        let properties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2],
        ]
        CGImageDestinationAddImage(
            destination,
            frame(CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            properties as CFDictionary)
        CGImageDestinationAddImage(
            destination,
            frame(CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LiveFrameJPEGRenderer.RenderError.encodeFailed
        }
        return data as Data
    }

    private func centerRGB(_ jpeg: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let data = image.dataProvider?.data as Data?
        else { return nil }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let offset = image.bytesPerRow * (image.height / 2) + bytesPerPixel * (image.width / 2)
        guard offset + 2 < data.count else { return nil }
        return Array(data[offset..<(offset + 3)])
    }
}
