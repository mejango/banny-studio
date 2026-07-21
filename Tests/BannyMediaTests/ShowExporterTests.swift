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
}
