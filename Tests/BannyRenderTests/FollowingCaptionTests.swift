import Foundation
import Testing
@testable import BannyCore
@testable import BannyRender

/// A caption on a performer who walks has to walk with them. Anchoring it once,
/// when the line was written, leaves it labelling the spot they left.
struct FollowingCaptionTests {
    func scene(x: Double, gSize: Double = 1.7) -> (SceneState, CharacterPose) {
        var s = SceneState(characters: [Character(body: .orange, x: x, name: "A", speed: 110)],
                           backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")])
        s.gSize = gSize
        let pose = SceneSimulator(state: s).pose(characterIndex: 0, at: 0)
        return (s, pose)
    }

    func anchor(x: Double, gSize: Double = 1.7,
                cue: Subtitle = Subtitle(text: "Hi.", start: 0, dur: 2, follow: true))
    -> (x: Double, y: Double) {
        let (s, pose) = scene(x: x, gSize: gSize)
        var moved = pose
        moved.x = x
        return FrameRenderer.captionAnchor(cue: cue, pose: moved, character: s.characters[0],
                                           scene: s, stageWidth: 1920, virtualHeight: 1080,
                                           outputHeight: 1080)
    }

    @Test func theCaptionTravelsWithTheSpeaker() {
        let left = anchor(x: 0.2)
        let right = anchor(x: 0.8)
        #expect(abs(left.x - 0.2) < 0.001)
        #expect(abs(right.x - 0.8) < 0.001)
        #expect(right.x - left.x > 0.5, "the caption did not move with the speaker")
    }

    @Test func aFixedCaptionStaysExactlyWhereItWasPut() {
        // Produce mode places captions by hand; those must not wander.
        let pinned = Subtitle(text: "Hi.", start: 0, dur: 2, x: 0.33, y: 0.44,
                              size: 1, width: 0.2)
        #expect(pinned.follow != true)
        let a = anchor(x: 0.2, cue: pinned)
        let b = anchor(x: 0.9, cue: pinned)
        #expect(a.x == 0.33 && a.y == 0.44)
        #expect(b.x == 0.33 && b.y == 0.44)
    }

    @Test func aFollowingCaptionSitsAboveTheHead() {
        for gSize in [1.0, 1.7, 2.2] {
            let (s, pose) = scene(x: 0.5, gSize: gSize)
            let placement = StageLayout.place(pose: pose, character: s.characters[0],
                                              scene: s, stageWidth: 1920, virtualHeight: 1080)
            let head = (placement.ty + 60 * placement.scale) / 1080
            let a = anchor(x: 0.5, gSize: gSize)
            #expect(a.y < head, "gSize \(gSize): caption is on the body")
            #expect(head - a.y < 0.16, "gSize \(gSize): caption is adrift")
        }
    }

    @Test func aFollowingCaptionCountsAsPlacedSoItGetsItsOwnBox() {
        let following = Subtitle(text: "Hi.", start: 0, dur: 2, follow: true)
        #expect(following.isPlaced, "a following caption must not join the bottom block")
        let plain = Subtitle(text: "Hi.", start: 0, dur: 2)
        #expect(!plain.isPlaced)
    }

    @Test func followSurvivesTheRoundTrip() throws {
        let cue = Subtitle(text: "Hi.", start: 0, dur: 2, size: 0.62, width: 0.2, follow: true)
        let back = try JSONDecoder().decode(Subtitle.self, from: JSONEncoder().encode(cue))
        #expect(back.follow == true)
        #expect(back == cue)
    }

    /// The compiler must stop recording a position of its own, or a stale x
    /// would quietly win over the live pose again.
    @Test func liveCaptionsAreEmittedAsFollowing() {
        var doc = ShowDocument(stage: SceneState(
            characters: [Character(body: .orange, x: -0.2, name: "A", speed: 110)],
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))
        doc.stage.reactionLibrary = LiveReactionLibrary.standard
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 3)
        c.apply([.enters(who: "A", zone: .middle),
                 .line(who: "A", text: "Over here.", kind: .say)], to: &doc, rng: &rng)
        let cue = doc.stage.characters[0].subs.first
        #expect(cue?.follow == true)
        #expect(cue?.x == nil, "a recorded x would freeze the caption in place")
        #expect(cue?.y == nil)
    }
}
