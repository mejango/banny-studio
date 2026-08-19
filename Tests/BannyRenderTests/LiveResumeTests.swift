import Foundation
import Testing
@testable import BannyCore
@testable import BannyRender

/// Prompting and fine-tuning are meant to alternate. Suspending a scene must
/// keep the evening, and picking it back up must not carry a stale belief about
/// where anybody is standing.
@MainActor
struct LiveResumeTests {
    func brief() -> LiveBrief {
        LiveBrief(premise: "A bar.",
                  cast: [LiveCastMember(name: "A", body: .orange),
                         LiveCastMember(name: "B", body: .alien)])
    }

    func opening() -> ShowDocument {
        var d = ShowDocument(stage: SceneState(
            characters: ["A", "B"].enumerated().map { i, name in
                var c = Character(body: .orange, x: i.isMultiple(of: 2) ? -0.2 : 1.2,
                                  depth: 0.06, size: 1, face: 1, name: name, speed: 110)
                c.presence = [VisibilityEvent(t: 0, visible: false)]
                return c
            },
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))
        d.stage.reactionLibrary = LiveReactionLibrary.standard
        d.stage.wings = 0.3
        return d
    }

    func director() -> LiveDirector {
        LiveDirector(brief: brief(), document: opening(), beats: { _ in [] })
    }

    func section() -> [LiveBeat] {
        var beats: [LiveBeat] = [.enters(who: "A", zone: .middle),
                                 .enters(who: "B", zone: .middle)]
        for i in 0..<8 {
            beats.append(.line(who: i.isMultiple(of: 2) ? "A" : "B",
                               text: "Something worth saying out loud here.", kind: .say))
        }
        return beats
    }

    @Test func suspendingKeepsTheEvening() {
        let d = director()
        d.apply(section())
        let said = d.transcript
        let written = d.writtenThrough
        #expect(!said.isEmpty)

        d.resume(with: d.document)
        #expect(d.transcript == said, "the transcript was thrown away")
        #expect(d.writtenThrough == written, "written work was lost")
        #expect(d.state == .awaitingReview, "should be ready to extend")
    }

    /// The whole point: a hand edit is the truth, and the compiler adopts it.
    @Test func theCompilerAdoptsWhatWasChangedByHand() {
        let d = director()
        d.apply(section())
        let at = d.writtenThrough

        // Fine-tune: shove A somewhere the compiler never put them.
        var edited = d.document
        edited.stage.characters[0].events.append(
            .key(t: at + 0.1, code: .arrowRight, down: true))
        edited.stage.characters[0].events.append(
            .key(t: at + 2.6, code: .arrowRight, down: false))
        d.resume(with: edited)

        // Now write more, and check the walk starts from where they actually are.
        d.extend()
        d.apply([.line(who: "A", text: "Right, where were we?", kind: .say),
                 .move(who: "A", zone: .far)])

        let sim = SceneSimulator(state: d.document.stage)
        let ended = sim.pose(characterIndex: 0, at: d.writtenThrough).x
        let far = LiveZone.far.span
        #expect(ended >= far.lowerBound - 0.08 && ended <= far.upperBound + 0.08,
                "A ended at \(ended), not the far zone: a stale position survived the hand edit")
    }

    @Test func aHandEditedSceneIsApprovedNotADraft() {
        let d = director()
        d.apply(section())
        d.resume(with: d.document)
        let kept = d.transcript
        // Try again must not eat work that was fine-tuned by hand.
        d.rewrite(feedback: "different")
        #expect(d.transcript == kept, "a rewrite discarded hand-edited work")
    }
}
