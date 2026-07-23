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

    func testEditableShowProfileEnforcesCanonicalIdentityStructure() {
        let asset = Asset(id: "asset", name: "Asset", kind: .image, file: "asset.png")
        let visual = ImageCue(id: "visual", assetID: asset.id, start: 0, dur: 1,
                              from: ImagePlacement())
        let sceneCue = BackgroundCue(id: "scene", assetID: asset.id, start: 0, dur: 1)
        let lightCue = LightCue(id: "light", start: 0, dur: 1, from: LightState())
        let stage = SceneState(
            audioTracks: [AudioTrack(id: "duplicate-track", name: "Media", cues: [visual])],
            imageTracks: [ImageTrack(id: "duplicate-track", name: "Visuals", cues: [visual])],
            backgroundTracks: [
                BackgroundTrack(id: "scenes-a", name: "Scenes", cues: [sceneCue]),
                BackgroundTrack(id: "scenes-b", name: "Scenes 2", cues: [sceneCue]),
            ],
            lightTracks: [LightTrack(id: "lights", name: "Lights",
                                     cues: [lightCue, lightCue])])
        let document = ShowDocument(version: 2, stage: stage, assets: [asset, asset])

        let messages = ShowLint.check(document: document, audioIDs: [],
                                      assetFileIDs: [asset.id], catalog: nil,
                                      profile: .editableShow)
            .map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("schema version must remain 4"), messages)
        XCTAssertTrue(messages.contains("exactly one Scenes track"), messages)
        XCTAssertTrue(messages.contains("Duplicate asset identifiers"), messages)
        XCTAssertTrue(messages.contains("Duplicate track identifiers"), messages)
        XCTAssertTrue(messages.contains("Duplicate visual cue identifiers"), messages)
        XCTAssertTrue(messages.contains("Duplicate scene cue identifiers"), messages)
        XCTAssertTrue(messages.contains("Duplicate light cue identifiers"), messages)
    }

    func testEditableShowProfileAllowsReusedAudioMediaReferences() {
        let clips = [
            AudioClip(id: "voice", name: "First", start: 0, dur: 1, srcDur: 1),
            AudioClip(id: "voice", name: "Second", start: 2, dur: 1, srcDur: 1),
        ]
        let document = ShowDocument(stage: SceneState(
            characters: [Character(body: .orange, clips: clips)],
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))

        XCTAssertEqual(ShowLint.check(document: document, audioIDs: ["voice"],
                                      assetFileIDs: [], catalog: nil,
                                      profile: .editableShow), [])
    }

    func testLightAndVisualPlacementRangesAreLinted() {
        let asset = Asset(id: "asset", name: "Asset", kind: .image, file: "asset.png")
        let visual = ImageCue(id: "visual", assetID: asset.id, start: 0, dur: 1,
                              from: ImagePlacement(scale: 0))
        let light = LightCue(id: "light", start: -1, dur: 0,
                             from: LightState(intensity: 2, size: 0))
        let document = ShowDocument(
            stage: SceneState(
                imageTracks: [ImageTrack(id: "visuals", name: "Visuals", cues: [visual])],
                lightTracks: [LightTrack(id: "lights", name: "Lights", cues: [light])]),
            assets: [asset])

        let messages = ShowLint.check(document: document, audioIDs: [],
                                      assetFileIDs: [asset.id], catalog: nil)
            .map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("non-positive placement scale"), messages)
        XCTAssertTrue(messages.contains("invalid range"), messages)
        XCTAssertTrue(messages.contains("intensity outside 0...1"), messages)
        XCTAssertTrue(messages.contains("non-positive size"), messages)
    }

    func testAudioFadesAndTimelineStructureAreLinted() {
        var clip = AudioClip(id: "voice", name: "Voice", start: 0, dur: 2, srcDur: 2)
        clip.fadeIn = 3
        var marker = TimelineMarker(id: "marker", name: "", start: 0)
        marker.start = -.infinity
        var section = TimelineMarker(id: "section", name: "Act", start: 1,
                                     kind: .section, duration: 2)
        section.duration = 0
        let document = ShowDocument(stage: SceneState(
            characters: [Character(body: .orange, clips: [clip])],
            markers: [marker, section]))

        let diagnostics = ShowLint.check(document: document, audioIDs: ["voice"],
                                         assetFileIDs: [], catalog: nil)
        let messages = diagnostics.map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("invalid fade-in"), messages)
        XCTAssertTrue(messages.contains("has no name"), messages)
        XCTAssertTrue(messages.contains("invalid start"), messages)
        XCTAssertTrue(messages.contains("invalid duration"), messages)
    }

    func testVoiceRecipeAndMouthTimingAreLinted() {
        var recipe = VoiceRecipe.preset(.robot)
        recipe.flavor = 2
        let clip = AudioClip(
            id: "speech",
            name: "Speech",
            start: 0,
            dur: 1,
            srcDur: 1,
            kind: .speech,
            mouthCues: [
                SpeechMouthCue(start: 0.8, dur: 0.4, shape: .open),
                SpeechMouthCue(start: 0.2, dur: 0.1, shape: .tight),
            ])
        let character = Character(
            body: .orange,
            clips: [clip],
            speechVoice: SpeechVoiceProfile(recipe: recipe))
        let document = ShowDocument(stage: SceneState(characters: [character]))

        let messages = ShowLint.check(
            document: document,
            audioIDs: ["speech"],
            assetFileIDs: [],
            catalog: nil).map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("voice recipe"), messages)
        XCTAssertTrue(messages.contains("not sorted"), messages)
        XCTAssertTrue(messages.contains("outside its source"), messages)
    }
}
