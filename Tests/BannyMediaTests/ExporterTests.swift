import Foundation
import Testing
@testable import BannyMedia
import BannyCore

@Test func contentDurationMatchesModelRules() {
    var state = SceneState()
    state.characters = [Character(body: .orange,
                                  clips: [AudioClip(id: "a", name: "a", start: 2, dur: 9, srcDur: 9)],
                                  events: [.key(t: 14.5, code: .keyM, down: true)])]
    #expect(ShowExporter.contentDuration(of: state) == 15.0)
}

@Test func resolveSegmentsFallsBackToWholeTimeline() {
    let doc = ShowDocument(stage: SceneState())
    let segs = ShowExporter.resolveSegments(document: doc)
    #expect(segs.count == 1)
    #expect(segs[0].from == 0)
}

@Test func backgroundCueResolution() {
    var stage = SceneState()
    stage.backgroundTracks = [BackgroundTrack(id: "b", name: "BG", cues: [
        BackgroundCue(id: "c1", assetID: "a1", start: 0, dur: 5),
        BackgroundCue(id: "c2", assetID: "a2", start: 5, dur: 5),
    ])]
    #expect(stage.activeBackgroundCue(at: 2)?.assetID == "a1")
    #expect(stage.activeBackgroundCue(at: 7)?.assetID == "a2")
    #expect(stage.activeBackgroundCue(at: 11) == nil)
    stage.backgroundTracks[0].hidden = true
    #expect(stage.activeBackgroundCue(at: 2) == nil)
}

@Test func imageCueInterpolates() {
    let cue = ImageCue(id: "i", assetID: "a", start: 2, dur: 4,
                       from: ImagePlacement(x: 0, y: 0, scale: 0.2),
                       to: ImagePlacement(x: 1, y: 0.5, scale: 0.4))
    #expect(cue.placement(at: 2) == ImagePlacement(x: 0, y: 0, scale: 0.2))
    let mid = cue.placement(at: 4)
    #expect(abs(mid.x - 0.5) < 1e-9 && abs(mid.y - 0.25) < 1e-9 && abs(mid.scale - 0.3) < 1e-9)
    #expect(cue.placement(at: 99).x == 1)
}
