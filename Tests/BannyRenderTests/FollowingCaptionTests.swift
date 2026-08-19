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

/// A caption that tracks a walk slides at walking pace and cannot be read.
/// It stays put for the length of its line instead, waiting where the speaker
/// will be standing when they finish.
struct ReadableCaptionTests {
    /// Someone walking left to right at the compiler's own pace.
    func walking(from x0: Double, rate: Double) -> (Double) -> Double {
        { t in x0 + rate * max(0, t) }
    }

    func cue(start: Double = 2, dur: Double = 3) -> Subtitle {
        Subtitle(text: "Over here.", start: start, dur: dur, follow: true)
    }

    /// The whole point: damping the position was not enough, because a damped
    /// box still travels at walking pace.
    @Test func aCaptionDoesNotMoveWhileItIsUp() {
        let walk = walking(from: 0.2, rate: 110.0 / 900)
        let line = cue(start: 2, dur: 3)
        let early = FrameRenderer.readableSpeakerX(for: line, live: walk(2.1), sample: walk)
        let late = FrameRenderer.readableSpeakerX(for: line, live: walk(4.9), sample: walk)
        #expect(early == late, "the caption travelled during its own line")
    }

    @Test func aCaptionWaitsWhereTheWalkEnds() {
        let walk = walking(from: 0.2, rate: 110.0 / 900)
        let line = cue(start: 2, dur: 3)
        let settled = FrameRenderer.readableSpeakerX(for: line, live: walk(2.0), sample: walk)
        #expect(abs(settled - walk(5.0)) < 1e-9, "the speaker will not arrive at their caption")
    }

    @Test func standingStillMovesNothing() {
        let still: (Double) -> Double = { _ in 0.42 }
        let settled = FrameRenderer.readableSpeakerX(for: cue(), live: 0.42, sample: still)
        #expect(abs(settled - 0.42) < 1e-9, "a caption drifted off a standing speaker")
    }

    /// Somebody who walks out during their own line must not leave the caption
    /// behind in the wings, labelling an empty stage.
    @Test func aCaptionIsNeverLeftOffstage() {
        let leaving: (Double) -> Double = { t in t < 4 ? 0.5 : -0.2 }
        let settled = FrameRenderer.readableSpeakerX(for: cue(start: 2, dur: 3),
                                                     live: 0.5, sample: leaving)
        #expect(settled == 0.5, "the caption followed them into the wings")
    }

    /// The bug this pair exists to stop: a performer speaks as they walk on, so
    /// the words start while they are still in the wings. Judged on the live
    /// pose, the caption appeared only once they had crossed the frame edge and
    /// a line with three seconds on the clock was on screen for one.
    @Test func aCaptionShowsWhileItsSpeakerIsStillWalkingOn() {
        let arriving: (Double) -> Double = { t in t < 4 ? -0.2 : 0.5 }
        let line = cue(start: 2, dur: 3)
        let settled = FrameRenderer.readableSpeakerX(for: line, live: arriving(2.2),
                                                     sample: arriving)
        #expect(!FrameRenderer.captionShows(anchoredAt: arriving(2.2), opacity: 1),
                "the speaker really is offstage — the test would prove nothing otherwise")
        #expect(FrameRenderer.captionShows(anchoredAt: settled, opacity: 1))
    }

    @Test func aCaptionLeavesWithASpeakerWhoWalksOff() {
        let leaving: (Double) -> Double = { t in t < 2.5 ? 0.5 : 1.3 }
        let settled = FrameRenderer.readableSpeakerX(for: cue(start: 2, dur: 3),
                                                     live: 1.3, sample: leaving)
        #expect(!FrameRenderer.captionShows(anchoredAt: settled, opacity: 1))
    }

    @Test func aDissolvedSpeakerTakesTheirCaptionWithThem() {
        #expect(!FrameRenderer.captionShows(anchoredAt: 0.5, opacity: 0.0))
        #expect(FrameRenderer.captionShows(anchoredAt: 0.5, opacity: 1.0))
    }

    /// Determinism matters: the same frame must resolve the same way whenever
    /// it is rendered, because export does not run in order.
    @Test func theSameFrameAlwaysResolvesTheSame() {
        let walk = walking(from: 0.1, rate: 0.12)
        let a = FrameRenderer.readableSpeakerX(for: cue(), live: walk(3.7), sample: walk)
        let b = FrameRenderer.readableSpeakerX(for: cue(), live: walk(3.7), sample: walk)
        #expect(a == b)
    }
}
