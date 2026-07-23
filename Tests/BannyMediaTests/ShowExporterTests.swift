import XCTest
import BannyCore
import BannyRender
@testable import BannyMedia

final class ShowExporterTests: XCTestCase {
    static let assetsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets")

    /// A show with zero audio clips must still export (video-only mp4).
    /// Regression: bounceAudio started an AVAudioEngine with an empty node
    /// graph, which segfaults in offline rendering.
    func testExportWithoutAudioClipsWritesVideoOnlyMp4() throws {
        let assets = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let doc = ShowDocument.starter(characterCount: 1)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-audio-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        try ShowExporter.export(
            document: doc, assets: assets,
            audioURL: { _ in nil }, assetURL: { _ in nil },
            options: ShowExporter.Options(size: CGSize(width: 854, height: 480),
                                          fps: 30, videoBitrate: 1_500_000),
            to: out)

        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000, "expected a non-trivial mp4")
    }

    func testExportCanCancelBeforeAllocatingWriter() throws {
        let assets = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertThrowsError(try ShowExporter.export(
            document: ShowDocument.starter(characterCount: 1),
            assets: assets,
            audioURL: { _ in nil }, assetURL: { _ in nil },
            to: out, shouldCancel: { true })) { error in
                guard case ShowExporter.ExportError.cancelled = error else {
                    return XCTFail("expected cancellation, got \(error)")
                }
            }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testExportPreflightIgnoresUnusedMissingLibraryAssets() {
        let used = Asset(id: "used", name: "Used", kind: .image, file: "used.png")
        let unused = Asset(id: "unused", name: "Unused", kind: .image, file: "unused.png")
        let cue = ImageCue(id: "visual", assetID: used.id, start: 0, dur: 1,
                           from: ImagePlacement())
        var document = ShowDocument.starter(characterCount: 1)
        document.assets = [used, unused]
        document.stage.backgroundTracks = [
            BackgroundTrack(id: "scenes", name: "Scenes"),
        ]
        document.stage.imageTracks = [
            ImageTrack(id: "visuals", name: "Visuals", cues: [cue]),
        ]

        XCTAssertEqual(
            ShowExportPreflight.errors(
                document: document,
                availableAudioIDs: [],
                availableAssetIDs: [used.id],
                catalog: nil),
            [])

        let errors = ShowExportPreflight.errors(
            document: document,
            availableAudioIDs: [],
            availableAssetIDs: [],
            catalog: nil)
        XCTAssertTrue(errors.contains { $0.contains(used.id) }, errors.joined(separator: "\n"))
        XCTAssertFalse(errors.contains { $0.contains(unused.id) }, errors.joined(separator: "\n"))
    }
}
