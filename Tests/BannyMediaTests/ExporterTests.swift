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

@Test func resolveSegmentsFallsBackToActiveScene() {
    let scene = Scene(id: "s1", name: "S", state: SceneState())
    let doc = ShowDocument(scenes: [scene])
    let segs = ShowExporter.resolveSegments(document: doc, activeScene: 0)
    #expect(segs.count == 1)
    #expect(segs[0].from == 0)
}
