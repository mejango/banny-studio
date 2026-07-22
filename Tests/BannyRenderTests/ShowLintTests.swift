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
        banny.clips = [
            AudioClip(id: "missing-audio", name: "voice", start: 0, dur: 2, srcDur: 2),
            AudioClip(id: "neg-start-audio", name: "flashback", start: -1, dur: 2, srcDur: 2),
        ]
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
        XCTAssertTrue(messages.contains("starts before 0"), messages)
        XCTAssertTrue(messages.contains("ghost-asset"), messages)
        XCTAssertTrue(messages.contains("unfiled"), messages)
        XCTAssertTrue(diags.allSatisfy { $0.severity == .error })
    }

    func testReactionReferencesRangesAndOutfitsAreLinted() throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let bad = ReactionDefinition(id: "bad", name: "Bad reaction", dur: 1, events: [
            .outfit(t: 2, slot: 12, name: "no-such-reaction-outfit"),
        ])
        let character = Character(body: .orange, reactions: [
            ReactionInstance(id: "missing-block", reactionID: "missing",
                             start: -1, dur: 0, intensity: 5),
        ])
        let doc = ShowDocument(stage: SceneState(characters: [character],
                                                  reactionLibrary: [bad]))
        let messages = ShowLint.check(document: doc, audioIDs: [], assetFileIDs: [],
                                      catalog: catalog).map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("outside its range"), messages)
        XCTAssertTrue(messages.contains("no-such-reaction-outfit"), messages)
        XCTAssertTrue(messages.contains("unknown reaction"), messages)
        XCTAssertTrue(messages.contains("invalid range"), messages)
        XCTAssertTrue(messages.contains("intensity outside"), messages)
    }

    func testNegativeVisualPlaybackPhaseIsLinted() {
        var cue = ImageCue(id: "visual", assetID: "asset", start: 0, dur: 1,
                           from: ImagePlacement())
        cue.playback.phaseOffset = -0.25
        let doc = ShowDocument(
            stage: SceneState(imageTracks: [
                ImageTrack(id: "visuals", name: "Visuals", cues: [cue]),
            ]),
            assets: [Asset(id: "asset", name: "Asset", kind: .image,
                           file: "asset.png")])
        let messages = ShowLint.check(document: doc, audioIDs: [],
                                      assetFileIDs: ["asset"], catalog: nil)
            .map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("playback phase before 0"), messages)
    }
}
