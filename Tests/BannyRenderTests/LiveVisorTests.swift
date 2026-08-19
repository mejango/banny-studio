import Foundation
import Testing
@testable import BannyCore
@testable import BannyRender

/// The Banny Vision Pro is a phone. It goes on when you are alone or shut out,
/// and it comes off the moment somebody addresses you — that courtesy is the
/// studio's job, not the script's.
struct LiveVisorTests {
    func opening(_ names: [String]) -> ShowDocument {
        var d = ShowDocument(stage: SceneState(
            characters: names.enumerated().map { i, name in
                let wing = i.isMultiple(of: 2) ? -0.2 : 1.2
                var c = Character(body: .orange, x: wing, depth: 0.06, size: 1,
                                  face: i.isMultiple(of: 2) ? 1 : -1,
                                  name: name, speed: 110)
                c.baseOutfit = [6: "cyberpunk-glasses"]
                c.presence = [VisibilityEvent(t: 0, visible: false)]
                return c
            },
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))
        d.stage.reactionLibrary = LiveReactionLibrary.standard
        d.stage.wings = 0.3
        return d
    }

    /// Every change to the glasses slot, in order.
    func glasses(_ doc: ShowDocument, _ index: Int) -> [(t: Double, name: String?)] {
        doc.stage.characters[index].events.compactMap {
            if case let .outfit(t, slot, name) = $0, slot == 6 { return (t, name) }
            return nil
        }
    }

    @Test func itComesOffWhenSomebodyComesOver() {
        var doc = opening(["Nell", "Ozzy"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 4)
        c.apply([
            .enters(who: "Nell", zone: .far),
            .wardrobe(who: "Nell", slot: 6, item: LiveCompiler.visor),
            .hold(seconds: 2),
            .enters(who: "Ozzy", zone: .far),      // joins her corner
        ], to: &doc, rng: &rng)

        let changes = glasses(doc, 0)
        #expect(changes.count == 2, "expected on, then off: \(changes)")
        #expect(changes.first?.name == LiveCompiler.visor)
        // And she gets her own face back, not a bare one.
        #expect(changes.last?.name == "cyberpunk-glasses")
        #expect(changes.last!.t > changes.first!.t)
    }

    @Test func nobodyAddressesTheRoomFromBehindIt() {
        var doc = opening(["Wes", "Rue"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 5)
        c.apply([
            .enters(who: "Wes", zone: .middle),
            .wardrobe(who: "Wes", slot: 6, item: LiveCompiler.visor),
            .hold(seconds: 2),
            .line(who: "Wes", text: "Fine. I heard that.", kind: .say),
        ], to: &doc, rng: &rng)

        let changes = glasses(doc, 0)
        #expect(changes.last?.name == "cyberpunk-glasses", "spoke wearing it")
        let spoke = doc.stage.characters[0].subs.first
        #expect(spoke != nil)
        #expect(changes.last!.t <= spoke!.start, "took it off after speaking")
    }

    /// Alone in a corner, it stays on — that is the whole point of it.
    @Test func aloneItStaysOn() {
        var doc = opening(["Gus", "Ozzy"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 6)
        c.apply([
            .enters(who: "Gus", zone: .far),
            .wardrobe(who: "Gus", slot: 6, item: LiveCompiler.visor),
            .hold(seconds: 2),
            .enters(who: "Ozzy", zone: .front),    // the other side of the room
            .hold(seconds: 2),
        ], to: &doc, rng: &rng)

        let changes = glasses(doc, 0)
        #expect(changes.count == 1, "somebody across the room took it off him")
        #expect(changes.first?.name == LiveCompiler.visor)
    }

    @Test func takingItOffTwiceIsNotWrittenTwice() {
        var doc = opening(["Nell", "Ozzy"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 7)
        c.apply([
            .enters(who: "Nell", zone: .middle),
            .wardrobe(who: "Nell", slot: 6, item: LiveCompiler.visor),
            .enters(who: "Ozzy", zone: .middle),
            .line(who: "Nell", text: "You are late.", kind: .say),
            .line(who: "Nell", text: "Again.", kind: .say),
        ], to: &doc, rng: &rng)

        let offs = glasses(doc, 0).filter { $0.name != LiveCompiler.visor }
        #expect(offs.count == 1, "it came off \(offs.count) times")
    }

    @MainActor
    @Test func theModelIsToldTheGrammarAndNotToWriteTheCourtesy() {
        let p = LiveDirector.prompt(
            brief: LiveBrief(premise: "A bar.",
                             cast: [LiveCastMember(name: "A", body: .orange)]),
            transcript: [], secondsToWrite: 30, elapsed: 30)
        #expect(p.contains("the way people use a phone in a room"))
        #expect(p.contains("the studio does that for you, so do not"))
        #expect(p.contains("putting them down at the same moment is an event"))
    }
}
