import XCTest
import BannyCore
import BannyRender
import BannyMedia

final class ShowPreviewTests: XCTestCase {
    static let assetsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets")

    func testPreviewWritesDecodablePNG() throws {
        let assets = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let doc = ShowDocument.starter(characterCount: 2)
        // `ShowPackage.Contents` has no public memberwise init (synthesized init on a
        // public struct is internal), so round-trip through write/read to build one —
        // equivalent to `Contents(document: doc, audioURLs: [:], assetURLs: [:])`.
        let pkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-pkg-\(UUID().uuidString).bannyshow")
        try ShowPackage.write(doc, to: pkgURL)
        defer { try? FileManager.default.removeItem(at: pkgURL) }
        let contents = try ShowPackage.read(from: pkgURL)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }

        try ShowPreview.writePNG(contents: contents, assets: assets, at: 0, to: out)

        let src = CGImageSourceCreateWithURL(out as CFURL, nil)
        let image = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(image?.width, 1920)
        XCTAssertEqual(image?.height, 1080)
    }

    func testYouTubeThumbnailIsDecodableAndUnderUploadLimit() throws {
        let assets = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let document = ShowDocument.starter(characterCount: 1)

        let data = try ShowPreview.thumbnailJPEG(
            document: document,
            assets: assets,
            assetURL: { _ in nil },
            at: 0)

        XCTAssertLessThanOrEqual(data.count, 2_000_000)
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(image?.width, 1280)
        XCTAssertEqual(image?.height, 720)
    }
}
