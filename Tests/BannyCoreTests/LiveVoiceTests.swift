import Foundation
import Testing
@testable import BannyCore

/// The antithesis — "That's not X. That's Y." — is a reflex rather than
/// writing, and once one character does it they all do. It is struck before it
/// reaches the screen, keeping the half that actually says something.
struct LiveVoiceTests {
    @Test func theReversalIsCutDownToWhatWasMeant() {
        #expect(LiveVoice.tidy("That's not cheating. That's continuity.")
                == "That's continuity.")
        #expect(LiveVoice.tidy("It isn't a bar. It's a waiting room.")
                == "It's a waiting room.")
        #expect(LiveVoice.tidy("This isn't a favour. This is a debt.")
                == "This is a debt.")
    }

    /// The comma version reached the screen: splitting only on full stops
    /// walked straight past it.
    @Test func theCommaVersionIsCaught() {
        #expect(LiveVoice.tidy("That's not thirst, that's a signal.")
                == "That's a signal.")
        #expect(LiveVoice.tidy("Five times for water. That's not thirst, that's a signal.")
                == "Five times for water. That's a signal.")
        #expect(LiveVoice.tidy("It's not a bar, it's a waiting room.")
                == "It's a waiting room.")
        #expect(LiveVoice.isAntithesis("That's not thirst, that's a signal."))
    }

    /// The dash version is the same construction wearing a different hat.
    @Test func theDashVersionIsCaughtToo() {
        #expect(LiveVoice.tidy("That's not luck — that's fourteen years.")
                == "That's fourteen years.")
        #expect(LiveVoice.tidy("You're not late – you're consistent.")
                == "You're consistent.")
    }

    @Test func itIsCaughtInTheMiddleOfALine() {
        let line = "Look at him. That's not confidence. That's a costume. Every week."
        let out = LiveVoice.tidy(line)
        #expect(out == "Look at him. That's a costume. Every week.")
        #expect(!LiveVoice.isAntithesis(out))
    }

    /// Everything that is not the tic must survive untouched — the filter is
    /// worse than useless if it quietly rewrites ordinary dialogue.
    @Test func ordinaryDialogueIsNeverTouched() {
        let lines = [
            "Evening.",
            "You are early, which for you is a kind of statement.",
            "That's not what I meant.",
            "It's not raining.",
            "That's the fourteenth time.",
            "I'm not saying he was wrong about the fish.",
            "This is a debt. That's understood.",
            "He said it wasn't a problem. Then he left.",
            "That's not cheating, and you know it.",
            "I told him, it's fine.",
            "Bring the glasses, it is late.",
            "He waited, we are all still here.",
        ]
        for line in lines {
            #expect(LiveVoice.tidy(line) == line, "rewrote an innocent line: \(line)")
        }
    }

    @Test func aLineThatIsOnlyTheTicKeepsItsSecondHalf() {
        let out = LiveVoice.tidy("That's not a hobby. That's an escape.")
        #expect(out == "That's an escape.")
        #expect(!out.isEmpty)
    }

    @Test func detectionAgreesWithTheEdit() {
        #expect(LiveVoice.isAntithesis("That's not cheating. That's continuity."))
        #expect(LiveVoice.isAntithesis("It's not a bar — it's a waiting room."))
        #expect(!LiveVoice.isAntithesis("That's not what I meant."))
        #expect(!LiveVoice.isAntithesis("Evening."))
    }

    /// It has to be gone from the performance, not merely from the helper.
    @Test func nobodyEverSaysItOnStage() {
        var doc = ShowDocument(stage: SceneState(
            characters: [Character(body: .orange, x: -0.2, name: "A", speed: 110)],
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))
        doc.stage.reactionLibrary = LiveReactionLibrary.standard
        doc.stage.wings = 0.3
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 2)
        c.apply([.enters(who: "A", zone: .middle),
                 .line(who: "A", text: "That's not cheating. That's continuity.",
                       kind: .say)], to: &doc, rng: &rng)

        let said = doc.stage.characters[0].subs.map(\.text)
        #expect(said == ["That's continuity."])
        #expect(said.allSatisfy { !LiveVoice.isAntithesis($0) })
    }

    @MainActor
    @Test func theModelIsAlsoToldNotTo() {
        let p = LiveDirector.prompt(
            brief: LiveBrief(premise: "A bar.",
                             cast: [LiveCastMember(name: "A", body: .orange)]),
            transcript: [], secondsToWrite: 30, elapsed: 0)
        #expect(p.contains("Never write the reversal"))
    }
}
