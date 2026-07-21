import XCTest
import BannyCore
@testable import BannyRender

final class ShowLintTests: XCTestCase {
    static let assetsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets")

    func testCleanDocumentHasNoDiagnostics() throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let doc = ShowDocument(stage: SceneState(characters: [Character(body: .orange)]))
        XCTAssertEqual(ShowLint.check(document: doc, audioIDs: [], assetFileIDs: [], catalog: catalog), [])
    }

    func testSeededErrorsAreCaught() throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        var banny = Character(body: .orange, name: "Banny 1")
        banny.baseOutfit = [4: "no-such-outfit"]
        banny.events = [.key(t: -1, code: .keyM, down: true)]
        banny.clips = [AudioClip(id: "missing-audio", name: "voice", start: 0, dur: 2, srcDur: 2)]
        var doc = ShowDocument(stage: SceneState(characters: [banny]))
        doc.stage.imageTracks = [ImageTrack(id: "img1", name: "Images", cues: [
            ImageCue(id: "cue1", assetID: "ghost-asset", start: 0, dur: 1, from: ImagePlacement()),
        ])]
        doc.assets = [Asset(id: "unfiled", name: "logo", kind: .image, file: "unfiled.png")]

        let diags = ShowLint.check(document: doc, audioIDs: [], assetFileIDs: [], catalog: catalog)
        let messages = diags.map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("no-such-outfit"), messages)
        XCTAssertTrue(messages.contains("t=-1"), messages)
        XCTAssertTrue(messages.contains("missing-audio"), messages)
        XCTAssertTrue(messages.contains("ghost-asset"), messages)
        XCTAssertTrue(messages.contains("unfiled"), messages)
        XCTAssertTrue(diags.allSatisfy { $0.severity == .error })
    }
}
