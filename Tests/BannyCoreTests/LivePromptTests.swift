import Foundation
import Testing
@testable import BannyCore

/// The prompt is the whole of what the model knows: it is sent fresh every
/// section, with no memory of its own.
@MainActor
struct LivePromptTests {
    func brief() -> LiveBrief {
        LiveBrief(premise: "A quiet bar.",
                  cast: [LiveCastMember(name: "Ozzy", body: .orange, prompt: "the host"),
                         LiveCastMember(name: "Rue", body: .original, prompt: "a regular")])
    }

    @Test func onlyTheFirstSectionIsTheOpening() {
        let first = LiveDirector.prompt(brief: brief(), transcript: [],
                                        secondsToWrite: 30, elapsed: 0)
        #expect(first.contains("OPENING"))

        // Thirty seconds in is section two, not the opening — calling it one
        // asked for a sparse room every time.
        let second = LiveDirector.prompt(brief: brief(), transcript: ["Ozzy: Evening."],
                                         secondsToWrite: 30, elapsed: 30)
        #expect(!second.contains("OPENING"), "section two was still called the opening")
        #expect(second.contains("already under way"))
    }

    @Test func everySectionIsSeparatedFromTheOneBefore() {
        let p = LiveDirector.prompt(brief: brief(), transcript: ["Ozzy: Evening."],
                                    secondsToWrite: 30, elapsed: 30,
                                    notes: ["drier"], direction: "someone leaves",
                                    cast: ["Ozzy", "Rue"])
        // Headings must not run on from the block above them.
        for heading in ["THE COMPANY SO FAR", "NOTES FROM THE DIRECTOR",
                        "WHAT HAPPENS NEXT", "SO FAR", "NOW", "HOW TO WRITE IT"] {
            #expect(p.contains("\n\n\(heading)"), "\(heading) runs on from the block above")
        }
    }

    @Test func theHouseStyleAsksForWhatWeWant() {
        let p = LiveDirector.prompt(brief: brief(), transcript: [], secondsToWrite: 30,
                                    elapsed: 0)
        #expect(p.contains("yes, and"))
        #expect(p.contains("small talk"))
        #expect(p.contains("recognisable with their name covered"))
        #expect(p.contains("You remember all of it"))
    }

    @Test func theHouseTropesAreAskedFor() {
        let p = LiveDirector.prompt(brief: brief(), transcript: [], secondsToWrite: 30,
                                    elapsed: 30, cast: ["Ozzy", "Rue"])
        // Nobody vanishes mid-conversation; the headset is the usual exit.
        #expect(p.contains("banny-vision-pro"))
        #expect(p.contains("steps away from the group first"))
        // One performer alone is a shot, not dead air.
        #expect(p.contains("standing alone"))
        // Nothing assumes a bar: the setting is whatever the premise says.
        for baked in ["their drink", "the evening", "the bar", "the party"] {
            #expect(!p.contains(baked), "the prompt assumes a setting: \(baked)")
        }
    }

    @Test func aClosedCastIsToldItIsClosed() {
        let open = LiveDirector.prompt(brief: brief(), transcript: [], secondsToWrite: 30,
                                       elapsed: 30, cast: ["Ozzy"], mayAddCast: true)
        #expect(open.contains("Strangers may turn up"))

        let closed = LiveDirector.prompt(brief: brief(), transcript: [], secondsToWrite: 30,
                                         elapsed: 30, cast: ["Ozzy"], mayAddCast: false)
        #expect(closed.contains("closed cast"))
        #expect(!closed.contains("Strangers may turn up"))
    }

    /// A tail of the last N lines is amnesia with a window: callbacks to how
    /// the evening began become impossible.
    @Test func theStartOfTheSceneIsNeverForgotten() {
        let long = (1...400).map { "Ozzy: line \($0)." }
        let remembered = LiveDirector.remembered(long)
        #expect(remembered.contains("line 1."), "the start of the evening was lost")
        #expect(remembered.contains("line 400."), "the most recent line was lost")
        #expect(remembered.contains("earlier on"))
        // Thinned, not complete: it is a memory, not a recording.
        #expect(remembered.count < long.joined(separator: "\n").count)
    }

    @Test func aShortSceneIsRememberedWhole() {
        let short = (1...20).map { "Rue: line \($0)." }
        let remembered = LiveDirector.remembered(short)
        #expect(remembered == short.joined(separator: "\n"))
    }
}

@MainActor
struct LiveWardrobePromptTests {
    func brief(dress: Bool = true, chosen: Bool = false) -> LiveBrief {
        LiveBrief(premise: "A hospital waiting room at 3am.",
                  cast: [LiveCastMember(name: "Ozzy", body: .orange, prompt: "the porter",
                                        outfitIsChosen: chosen),
                         LiveCastMember(name: "Rue", body: .original, prompt: "waiting")],
                  mayDressCast: dress,
                  wardrobe: ["12": ["chef-hat", "club-beanie"],
                             "11": ["doc-coat", "punk-jacket"],
                             "13": ["beer", "baguette"]])
    }

    @Test func theSceneIsToldWhatThereIsToWear() {
        let p = LiveDirector.prompt(brief: brief(), transcript: [],
                                    secondsToWrite: 30, elapsed: 0)
        #expect(p.contains("WARDROBE"))
        #expect(p.contains("doc-coat") && p.contains("club-beanie"))
        #expect(p.contains("before anyone's first `enters`"))
    }

    /// Only real items are offered, so a costume cannot be invented.
    @Test func nothingIsOfferedThatDoesNotExist() {
        let p = LiveDirector.prompt(brief: brief(), transcript: [],
                                    secondsToWrite: 30, elapsed: 0)
        let listed = ["chef-hat", "club-beanie", "doc-coat", "punk-jacket",
                      "beer", "baguette"]
        // Every wardrobe name in the prompt is one we actually handed it.
        for line in p.split(separator: "\n") where line.contains("head top:")
            || line.contains("suit top:") || line.contains("hand:") {
            for item in line.split(separator: ":")[1].split(separator: ",") {
                #expect(listed.contains(item.trimmingCharacters(in: .whitespaces)))
            }
        }
    }

    @Test func aChosenCostumeIsLeftAlone() {
        let p = LiveDirector.prompt(brief: brief(chosen: true), transcript: [],
                                    secondsToWrite: 30, elapsed: 0)
        #expect(p.contains("Ozzy is dressed already"))
    }

    @Test func turningItOffAsksForNoWardrobeAtAll() {
        let p = LiveDirector.prompt(brief: brief(dress: false), transcript: [],
                                    secondsToWrite: 30, elapsed: 0)
        #expect(!p.contains("WARDROBE"))
    }

    /// Dressing happens once, at the top. Later sections must not restage it.
    @Test func onlyTheOpeningSectionDressesAnybody() {
        let later = LiveDirector.prompt(brief: brief(), transcript: ["Ozzy: Evening."],
                                        secondsToWrite: 30, elapsed: 30)
        #expect(!later.contains("WARDROBE"))
    }
}

@MainActor
struct LiveReferenceTests {
    func brief(_ links: String) -> LiveBrief {
        LiveBrief(premise: "A bar.", references: links,
                  cast: [LiveCastMember(name: "A", body: .orange)])
    }

    @Test func linksReachTheModelWholeAndInTheirOwnSection() {
        let p = LiveDirector.prompt(brief: brief("https://example.com/the-thing\nand a note about it"),
                                    transcript: [], secondsToWrite: 30, elapsed: 0)
        #expect(p.contains("WHAT THEY HAVE BEEN LOOKING AT"))
        #expect(p.contains("https://example.com/the-thing"))
        #expect(p.contains("and a note about it"))
        // Half-remembered in passing, not recited.
        #expect(p.contains("never recited"))
    }

    @Test func noLinksMeansNoSection() {
        let p = LiveDirector.prompt(brief: brief("   "), transcript: [],
                                    secondsToWrite: 30, elapsed: 0)
        #expect(!p.contains("WHAT THEY HAVE BEEN LOOKING AT"))
    }

    @Test func theSectionIsSeparatedLikeEveryOther() {
        let p = LiveDirector.prompt(brief: brief("https://example.com"),
                                    transcript: [], secondsToWrite: 30, elapsed: 0)
        #expect(p.contains("\n\nWHAT THEY HAVE BEEN LOOKING AT"))
    }
}

@MainActor
struct LiveStrayLinkTests {
    /// People paste links where they are thinking, not where a field expects
    /// them. A link in the premise gets the same handling as one in the field.
    @Test func aLinkInThePremiseIsStillTreatedAsReading() {
        let brief = LiveBrief(
            premise: "A quiet bar. Philosophizing about "
                   + "https://www.preprints.org/frontend/manuscript/4d443/download_pub",
            cast: [LiveCastMember(name: "A", body: .orange)])
        let p = LiveDirector.prompt(brief: brief, transcript: [],
                                    secondsToWrite: 30, elapsed: 0)
        #expect(p.contains("WHAT THEY HAVE BEEN LOOKING AT"))
        #expect(p.contains("preprints.org"))
        #expect(p.contains("never recited"))
        // And the premise itself is untouched.
        #expect(p.contains("A quiet bar. Philosophizing about"))
    }

    @Test func aLinkIsNotListedTwice() {
        let url = "https://example.com/paper"
        let brief = LiveBrief(premise: "They argue about \(url).",
                              references: url,
                              cast: [LiveCastMember(name: "A", body: .orange)])
        let p = LiveDirector.prompt(brief: brief, transcript: [],
                                    secondsToWrite: 30, elapsed: 0)
        let section = p.components(separatedBy: "WHAT THEY HAVE BEEN LOOKING AT")[1]
            .components(separatedBy: "\n\n")[0]
        #expect(section.components(separatedBy: url).count - 1 == 1,
                "the same link was handed over twice")
    }

    @Test func proseWithNoLinksAsksForNoReading() {
        let brief = LiveBrief(premise: "A quiet bar at the end of the day.",
                              cast: [LiveCastMember(name: "A", body: .orange)])
        let p = LiveDirector.prompt(brief: brief, transcript: [],
                                    secondsToWrite: 30, elapsed: 0)
        #expect(!p.contains("WHAT THEY HAVE BEEN LOOKING AT"))
    }

    @Test func everyLinkInTheTextIsFound() {
        let found = LiveDirector.urls(in: "See https://a.example/x and http://b.example/y too.")
        #expect(found.count == 2)
        #expect(found.contains { $0.contains("a.example") })
    }
}
