import Foundation
import Testing
@testable import BannyCore

/// A live scene is commissioned in stretches so the first half-minute can be
/// judged and thrown away cheaply. These cover that loop.
@MainActor
struct LiveDirectorReviewTests {
    func brief(duration: Double = 900, mayAddCast: Bool = true) -> LiveBrief {
        LiveBrief(duration: duration, premise: "A bar.",
                  cast: [LiveCastMember(name: "A", body: .orange),
                         LiveCastMember(name: "B", body: .alien)],
                  mayAddCast: mayAddCast)
    }

    func opening(_ brief: LiveBrief) -> ShowDocument {
        var d = ShowDocument(stage: SceneState(
            characters: brief.cast.map {
                Character(body: $0.body, x: -0.2, name: $0.name, speed: 110)
            },
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))
        d.stage.reactionLibrary = LiveReactionLibrary.standard
        d.stage.wings = 0.3          // as LiveSceneBuilder sets it
        return d
    }

    func director(_ b: LiveBrief) -> LiveDirector {
        LiveDirector(brief: b, document: opening(b), beats: { _ in [] })
    }

    /// A hold is capped at 6s by the compiler, so length comes from beats.
    func batch(lines: Int, enter: Bool = true) -> [LiveBeat] {
        var beats: [LiveBeat] = enter ? [.enters(who: "A", zone: .middle)] : []
        for i in 0..<lines {
            beats.append(.line(who: i.isMultiple(of: 2) ? "A" : "B",
                               text: "A line of dialogue long enough to take a moment.",
                               kind: .say))
            beats.append(.hold(seconds: 2))
        }
        return beats
    }

    /// Short of the commissioned thirty seconds.
    func shortBatch() -> [LiveBeat] { batch(lines: 2) }

    /// Comfortably past it.
    func longBatch() -> [LiveBeat] { batch(lines: 8) }

    @Test func onlyTheFirstHalfMinuteIsCommissioned() {
        let d = director(brief())
        #expect(d.commissioned == LiveDirector.stretch)
        #expect(LiveDirector.stretch == 30)
    }

    @Test func reachingTheCommissionStopsForReview() {
        let d = director(brief())
        d.apply(shortBatch())
        #expect(d.state == .performing, "20s in, there is more to write")
        d.apply(longBatch())
        #expect(d.writtenThrough >= 30)
        #expect(d.state == .awaitingReview, "past 30s it must stop and ask")
    }

    @Test func extendingCommissionsMoreAndKeepsWhatWasWritten() {
        let d = director(brief())
        d.apply(longBatch())
        let written = d.writtenThrough
        let said = d.transcript
        d.extend()
        #expect(d.commissioned == written + LiveDirector.stretch)
        #expect(d.state == .writing)
        #expect(d.writtenThrough == written, "extending must not discard anything")
        #expect(d.transcript == said)
    }

    @Test func extendingNeverRunsPastTheSceneLength() {
        let d = director(brief(duration: 60))
        d.apply(longBatch())
        d.extend()
        #expect(d.commissioned == 60)
    }

    /// The whole point of building in chunks: redoing one must not cost you the
    /// ones already approved.
    @Test func aRewriteKeepsEveryApprovedSection() {
        let d = director(brief())
        d.apply(longBatch())                       // section one
        let firstSaid = d.transcript
        #expect(!firstSaid.isEmpty)
        d.extend()                                 // approve it
        let boundary = d.chunkStart
        #expect(boundary > 0)

        d.apply(batch(lines: 8, enter: false))     // section two
        #expect(d.transcript.count > firstSaid.count)

        d.rewrite(feedback: "too shouty")
        #expect(d.writtenThrough == boundary, "the rewrite ate an approved section")
        #expect(d.transcript == firstSaid, "approved dialogue was thrown away")
        #expect(d.chunkStart == boundary)
        #expect(d.commissioned == boundary + LiveDirector.stretch)
    }

    @Test func everySectionIsTheSameHalfMinute() {
        let d = director(brief())
        #expect(d.commissioned == 30)
        d.apply(longBatch())
        let one = d.writtenThrough
        d.extend()
        #expect(abs(d.commissioned - one - LiveDirector.stretch) < 1e-9)
        d.apply(batch(lines: 8, enter: false))
        let two = d.writtenThrough
        d.extend()
        #expect(abs(d.commissioned - two - LiveDirector.stretch) < 1e-9)
    }

    @Test func sectionsAreContinuousWithNoGapOrOverlap() {
        let d = director(brief())
        d.apply(longBatch())
        let endOfOne = d.writtenThrough
        d.extend()
        #expect(d.chunkStart == endOfOne, "section two must start where one ended")
    }

    /// The first section has nothing approved before it, so redoing it does
    /// return to an empty stage.
    @Test func rewritingTheFirstSectionGoesBackToAnEmptyStage() {
        let d = director(brief())
        d.apply([.enters(who: "A", zone: .middle),
                 .line(who: "A", text: "Evening.", kind: .say),
                 .hold(seconds: 40)])
        #expect(!d.transcript.isEmpty)
        #expect(d.document.stage.characters[0].subs.count > 0)

        d.rewrite(feedback: "too formal")
        #expect(d.writtenThrough == 0)
        #expect(d.transcript.isEmpty)
        #expect(d.commissioned == LiveDirector.stretch)
        #expect(d.state == .writing)
        // The stage must be clean, not a second attempt layered on the first.
        #expect(d.document.stage.characters.allSatisfy { $0.subs.isEmpty })
        #expect(d.document.stage.characters.allSatisfy { $0.events.isEmpty })
    }

    @Test func aRewriteMovesTheSceneOnSoTheViewCanResetThePlayhead() {
        let d = director(brief())
        let before = d.generation
        d.rewrite(feedback: "again")
        #expect(d.generation == before + 1)
    }

    /// Feedback accumulates, or "less of that" stops meaning anything by the
    /// third attempt.
    @Test func everyNoteReachesTheModelIncludingOlderOnes() {
        let b = brief()
        let one = LiveDirector.prompt(brief: b, transcript: [], secondsToWrite: 30,
                                      elapsed: 0, notes: ["fewer puns"])
        #expect(one.contains("fewer puns"))

        let two = LiveDirector.prompt(brief: b, transcript: [], secondsToWrite: 30,
                                      elapsed: 0, notes: ["fewer puns", "slower"])
        #expect(two.contains("fewer puns") && two.contains("slower"))

        let none = LiveDirector.prompt(brief: b, transcript: [], secondsToWrite: 30,
                                       elapsed: 0)
        #expect(!none.contains("DIRECTOR"), "no notes, no notes section")
    }

    /// Extend carries an open note for the coming stretch, and it must not
    /// linger the way a correction does.
    @Test func aDirectionAppliesToTheNextStretchOnly() {
        let b = brief()
        let one = LiveDirector.prompt(brief: b, transcript: [], secondsToWrite: 60,
                                      elapsed: 30, direction: "someone drops a glass")
        #expect(one.contains("someone drops a glass"))
        #expect(one.contains("WHAT HAPPENS NEXT"))

        let after = LiveDirector.prompt(brief: b, transcript: [], secondsToWrite: 60,
                                        elapsed: 90)
        #expect(!after.contains("WHAT HAPPENS NEXT"), "the direction outlived its stretch")
    }

    @Test func aDirectionMayAskForSomebodyNew() {
        let d = director(brief())
        d.apply(longBatch())
        d.extend(direction: "a stranger called Wren comes in")
        #expect(d.state == .writing)

        // The script walks somebody on who was never in the cast.
        d.apply([.enters(who: "Wren", zone: .front),
                 .line(who: "Wren", text: "Room for one more?", kind: .say)])
        let names = d.document.stage.characters.map(\.name)
        #expect(names.contains("Wren"), "the newcomer never joined the company")
        let wren = d.document.stage.characters.first { $0.name == "Wren" }
        #expect(wren?.subs.isEmpty == false, "the newcomer was not given their line")
        #expect(wren?.baseOutfit.isEmpty == false, "the newcomer arrived undressed")
    }

    /// A closed cast stays closed however the script is written.
    @Test func aClosedCastNeverGrows() {
        let d = LiveDirector(brief: brief(mayAddCast: false),
                             document: opening(brief(mayAddCast: false)),
                             beats: { _ in [] })
        d.apply([.enters(who: "Stranger", zone: .middle),
                 .line(who: "Stranger", text: "Room for one more?", kind: .say)])
        #expect(!d.document.stage.characters.contains { $0.name == "Stranger" })
        #expect(d.document.stage.characters.count == 2)
    }

    @Test func onlyAnEntranceCanIntroduceSomebody() {
        let d = director(brief())
        // A misspelt name in a line must not conjure a second person.
        d.apply([.line(who: "Ozzy", text: "Where is he?", kind: .say)])
        #expect(!d.document.stage.characters.contains { $0.name == "Ozzy" })
    }

    @Test func theCompanyStopsGrowingAtTheLimit() {
        let d = director(brief())
        for i in 0..<20 {
            d.apply([.enters(who: "Extra\(i)", zone: .middle)])
        }
        #expect(d.document.stage.characters.count <= LiveDirector.castLimit)
    }

    @Test func twoAttemptsAtTheSameOpeningDifferFromEachOther() {
        let b = brief()
        let d = director(b)
        d.apply(longBatch())
        let first = d.document
        d.rewrite(feedback: "")
        d.apply(longBatch())
        // Same beats, but a fresh draw — the staging must not be a carbon copy.
        #expect(d.document != first)
    }
}
