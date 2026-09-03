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
        #expect(first.contains("OPENING HOOK — MANDATORY"))
        #expect(first.contains("first thirty seconds must earn the next thirty"))
        #expect(first.contains("By the second spoken line"))
        #expect(first.contains("makes stopping feel premature"))

        // Thirty seconds in is section two, not the opening — calling it one
        // asked for a sparse room every time.
        let second = LiveDirector.prompt(brief: brief(), transcript: ["Ozzy: Evening."],
                                         secondsToWrite: 30, elapsed: 30)
        #expect(!second.contains("OPENING"), "section two was still called the opening")
        #expect(second.contains("already under way"))
        #expect(!second.contains("OPENING HOOK — MANDATORY"),
                "later stretches were incorrectly treated as a new hook")
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
        #expect(p.contains("Small talk is occasional"))
        #expect(p.contains("never the main substance"))
        #expect(p.contains("do not spend the scene warming up"))
        #expect(p.contains("CAUSAL LINE RULE — MANDATORY"))
        #expect(p.contains("AUDIENCE-BLIND DIALOGUE — THE BRIEF IS PRIVATE"))
        #expect(p.contains("audience never reads"))
        #expect(p.contains("by spoken line four"))
        #expect(p.contains("Do not rely on a fact that exists only in this brief"))
        #expect(p.contains("Natural exposition is information somebody uses"))
        #expect(p.contains("every segue between successive spoken lines"))
        #expect(p.contains("exactly one of two relationships"))
        #expect(p.contains("direct consequence"))
        #expect(p.contains("direct narrative tension"))
        #expect(p.contains("Test with one word, never both"))
        #expect(p.contains("Avoid \"and then\""))
        #expect(p.contains("build one shared situation together"))
        #expect(p.contains("return to the shared thread and advance it"))
        #expect(p.contains("banter, one-offs"))
        #expect(p.contains("Give the stretch a dramatic engine"))
        #expect(p.contains("big questions into concrete choices"))
        #expect(p.contains("The laugh and the drama should tighten the same"))
        #expect(p.contains("COMEDY ENGINE — MANDATORY"))
        #expect(p.contains("at least 2 distinct comic turns"))
        #expect(p.contains("genuinely funny in the moment AND reveals character"))
        #expect(p.contains("make the joke become the next story problem"))
        #expect(p.contains("Puns, references, random weirdness"))
        #expect(p.contains("creatively ambitious and causally strict"))
        #expect(p.contains("one surprising"))
        #expect(p.contains("rather than rebooting it"))
        #expect(p.contains("BUILD THE STRETCH AS ONE MOVEMENT"))
        #expect(p.contains("Cut orphan lines"))
        #expect(p.contains("More than one conversation may be alive on screen"))
        #expect(p.contains("separate zones may deliberately hold separate conversations"))
        #expect(!p.contains("Every line answers the one before it"))
        #expect(p.contains("recognisable with their name covered"))
        #expect(p.contains("You remember all of it"))
    }

    @Test func aLooseArcFeedsAnImmutableForwardWritingPass() throws {
        let assignment = LiveDirector.prompt(brief: brief(), transcript: [],
                                             secondsToWrite: 30, elapsed: 0)
        let planning = LiveDirector.planningPrompt(assignment: assignment)
        #expect(planning.contains("Produce ONE loose dramatic"))
        #expect(planning.contains("DRAMATIC COMPASS"))
        #expect(planning.contains("OBJECTIVE —"))
        #expect(planning.contains("STAKES —"))
        #expect(planning.contains("QUESTION —"))
        #expect(planning.contains("Do NOT plan future lines"))
        #expect(!planning.contains("CHAIN — 4–6 causal steps"))
        #expect(planning.contains("Mystery may conceal an answer"))

        let compass = "OBJECTIVE — Goal | OBSTACLE — Block | STAKES — Cost | "
            + "FOCUS — Object | QUESTION — Question | DIRECTION — Possible pressure"

        let production = LiveDirector.plannedAssignment(assignment: assignment,
                                                        plan: compass)
        #expect(production.contains("DRAMATIC COMPASS"))
        #expect(production.contains("THE ROUTE STAYS OPEN"))

        let writing = LiveDirector.forwardWritingPrompt(assignment: production,
                                                        targetTurns: 6)
        #expect(writing.contains("exactly 6 spoken turns"))
        #expect(writing.contains("Invent only the current turn"))
        #expect(writing.contains("Never outline future lines"))
        #expect(writing.contains("Earlier turns are immutable"))
        #expect(writing.contains("Respond backward and open forward"))
        #expect(writing.contains("Do not output those decisions"))
        #expect(writing.contains("Never emit `WRITER TURN`"))
        #expect(writing.contains("audience has never"))
        #expect(writing.contains("through conflict and intention rather than a synopsis"))

        let forward = try LiveDirector.parseForwardDraft([
            .enters(who: "Ozzy", zone: .middle),
            .line(who: "Ozzy", text: "The door locks at six.", kind: .say),
            .line(who: "Rue", text: "[BUT] The key is missing.", kind: .say),
        ])
        #expect(forward.receipts.count == 2)
        #expect(forward.receipts[1].relation == .but)
        #expect(forward.beats.count == 3, "private receipts must not reach the stage")

        let judge = LiveDirector.causalJudgePrompt(assignment: production,
                                                   taggedScript: forward.beats)
        #expect(judge.contains("independent, adversarial causal editor"))
        #expect(judge.contains("did not write this script"))
        #expect(judge.contains("distinctive word or action from each"))
        #expect(judge.contains("FAIL BUT"))
        #expect(judge.contains("OPENING GATE"))
        #expect(judge.contains("grounded curiosity immediately"))
        #expect(judge.contains("COMEDY GATE"))
        #expect(judge.contains("required number of distinct, earned comic turns"))
        #expect(judge.contains("mark the weakest segue FAIL"))
        #expect(judge.contains("audience-blind reading using ONLY the spoken text"))
        #expect(judge.contains("Do not use THE SCENE, THE CAST"))
        #expect(judge.contains("From the dialogue alone, by line four"))
        #expect(judge.range(of: "TAGGED SCRIPT TO JUDGE")!.lowerBound
                < judge.range(of: "PRODUCTION ASSIGNMENT —")!.lowerBound)
    }

    @Test func plannerEnvelopeContainsOneCompleteLooseCompass() throws {
        let compass = "OBJECTIVE — Goal | OBSTACLE — Block | STAKES — Cost | "
            + "FOCUS — Object | QUESTION — Question | DIRECTION — Possible pressure"
        let beats: [LiveBeat] = [
            .line(who: "DRAMATIC COMPASS", text: compass, kind: .say),
        ]
        #expect(try LiveDirector.parseDramaticCompass(beats) == compass)
        #expect(throws: LiveDirector.ProductionPipelineError.self) {
            try LiveDirector.parseDramaticCompass([])
        }
    }

    @Test func forwardDraftRejectsAnUntaggedSecondTurn() {
        let malformed: [LiveBeat] = [
            .line(who: "A", text: "We leave at six.", kind: .say),
            .line(who: "B", text: "No.", kind: .say),
        ]
        #expect(throws: LiveDirector.ProductionPipelineError.self) {
            try LiveDirector.parseForwardDraft(malformed)
        }
    }

    @Test func causalCertificationRequiresOneExclusiveRelationshipPerSegue() throws {
        let tagged: [LiveBeat] = [
            .line(who: "Mox", text: "The wall comes down at six.", kind: .say),
            .gesture(who: "Mox", name: "point"),
            .line(who: "Vey", text: "[BUT] It is load-bearing.", kind: .say),
            .line(who: "Mox", text: "[THEREFORE] We brace it first.", kind: .say),
        ]
        let certified = try LiveDirector.certifyCausalSegues(tagged)
        #expect(certified.links.map(\.relation) == [.but, .therefore])
        #expect(certified.links[0].before == "Mox: The wall comes down at six.")
        #expect(certified.links[0].after == "Vey: It is load-bearing.")
        #expect(certified.beats == [
            .line(who: "Mox", text: "The wall comes down at six.", kind: .say),
            .gesture(who: "Mox", name: "point"),
            .line(who: "Vey", text: "It is load-bearing.", kind: .say),
            .line(who: "Mox", text: "We brace it first.", kind: .say),
        ])
    }

    @Test func causalCertificationRejectsAnUnclassifiedSegue() {
        let untagged: [LiveBeat] = [
            .line(who: "Mox", text: "The wall comes down at six.", kind: .say),
            .line(who: "Vey", text: "Nine hours is six hundred.", kind: .say),
        ]
        #expect(throws: LiveDirector.CausalCertificationError.self) {
            try LiveDirector.certifyCausalSegues(untagged)
        }
    }

    @Test func independentJudgeMustExplainEachSpecificBridge() throws {
        let links = [LiveCausalLink(
            before: "Mox: The wall comes down at six.", relation: .but,
            after: "Vey: The wall is load-bearing.")]
        let verdicts = try LiveDirector.parseCausalVerdicts([
            .line(who: "PASS BUT",
                  text: "The load-bearing wall blocks Mox from bringing the wall down safely.",
                  kind: .say),
        ], expected: links)
        #expect(verdicts.count == 1)
        #expect(verdicts[0].passed)

        #expect(throws: LiveDirector.ProductionPipelineError.self) {
            try LiveDirector.parseCausalVerdicts([
                .line(who: "PASS BUT", text: "This creates tension and advances the story.",
                      kind: .say),
            ], expected: links)
        }
    }

    @Test func repeatedBackdropsReceiveDifferentStoryEngines() {
        let first = LiveDirector.creativeLens(seed: 10)
        let second = LiveDirector.creativeLens(seed: 11)
        #expect(first != second)
        #expect(first.contains("This varies the telling, not the story"))
        #expect(first.contains("ONE fixed scene spine"))
        #expect(first.contains("Approach:"))
        #expect(first.contains("continuation means consequence"))

        let asked = LiveDirector.prompt(brief: brief(), transcript: [],
                                        secondsToWrite: 30, elapsed: 0,
                                        creativeLens: first)
        #expect(asked.contains(first))
        #expect(asked.contains("Never import a stock"))
    }

    @Test func theHouseTropesAreAskedFor() {
        let p = LiveDirector.prompt(brief: brief(), transcript: [], secondsToWrite: 30,
                                    elapsed: 30, cast: ["Ozzy", "Rue"])
        // Nobody vanishes mid-conversation; the headset is the usual exit.
        #expect(p.contains("banny-vision-pro"))
        #expect(p.contains("always available as a phone-like prop"))
        #expect(p.contains("bored, alone, waiting"))
        #expect(p.contains("wanting to look something up"))
        #expect(p.contains("interacting with an AI"))
        #expect(p.contains("steps away from the group first"))
        // One performer alone is a shot, not dead air.
        #expect(p.contains("standing alone"))
        // Nothing assumes a bar: the setting is whatever the premise says.
        for baked in ["their drink", "the evening", "the bar", "the party"] {
            #expect(!p.contains(baked), "the prompt assumes a setting: \(baked)")
        }
    }

    /// The prompt was held to this from the start; the wardrobe was not, and a
    /// bar's props went on everyone whatever room they walked into.
    @Test func nobodyIsHandedAPropBeforeTheRoomIsKnown() {
        for n in 0..<24 {
            let look = LiveCastMember.defaultOutfit(n)
            #expect(look["13"] == nil,
                    "look \(n) arrives holding \(look["13"] ?? "") whatever the scene is")
            #expect(!look.isEmpty, "look \(n) turns up undressed")
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
    func brief(dress: Bool = true, chosen: Bool = false,
               mayChange: Bool = false) -> LiveBrief {
        LiveBrief(premise: "A hospital waiting room at 3am.",
                  cast: [LiveCastMember(name: "Ozzy", body: .orange, prompt: "the porter",
                                        mayChangeWardrobe: mayChange,
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
        #expect(p.contains("Slot 13 is not decorative clothing"))
        #expect(p.contains("creates a concrete action"))
        #expect(p.contains("do not choose one the dialogue and action will ignore"))
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

    @Test func carriedPropsRemainFactsForEveryWritingPass() {
        let p = LiveDirector.prompt(
            brief: brief(), transcript: ["Ozzy: We have a problem."],
            secondsToWrite: 30, elapsed: 30,
            currentOutfits: [
                "Ozzy": ["11": "doc-coat", "13": "baguette"],
                "Rue": ["12": "club-beanie"],
            ])
        #expect(p.contains("visible now: suit top doc-coat, carrying baguette"))
        #expect(p.contains("VISIBLE HAND PROPS — ESTABLISHED STORY FACTS"))
        #expect(p.contains("Ozzy is carrying baguette"))
        #expect(p.contains("Create opportunities to use"))
        #expect(p.contains("not a line that merely describes"))
    }

    @Test func currentWardrobeIsReadFromThePerformedTimeline() {
        var character = Character(body: .orange, name: "Ozzy")
        character.baseOutfit = [11: "doc-coat"]
        character.events = [.outfit(t: 2, slot: 13, name: "beer")]
        let doc = ShowDocument(stage: SceneState(characters: [character]))
        #expect(LiveDirector.currentOutfits(in: doc, at: 1)["Ozzy"]?["13"] == nil)
        #expect(LiveDirector.currentOutfits(in: doc, at: 3)["Ozzy"]?["13"] == "beer")
        #expect(LiveDirector.currentOutfits(in: doc, at: 3)["Ozzy"]?["11"] == "doc-coat")
    }

    @Test func laterPassesKnowHowToPerformAnEarnedOutfitChange() {
        let p = LiveDirector.prompt(
            brief: brief(mayChange: true), transcript: ["Ozzy: I need a disguise."],
            secondsToWrite: 30, elapsed: 30,
            currentOutfits: ["Ozzy": ["11": "doc-coat"]])
        #expect(p.contains("STORY-EARNED COSTUME CHANGES"))
        #expect(p.contains("Ozzy may change outfit"))
        #expect(p.contains("11 suit top: doc-coat, punk-jacket"))
        #expect(p.contains(#"{"beat":"wardrobe","who":"NAME","slot":11"#))
        #expect(p.contains("performs the visible change"))
        #expect(p.contains("multiple consecutive beats for a complete transformation"))
    }

    @Test func fixedPerformersAreNotOfferedStoryCostumeChanges() {
        let p = LiveDirector.prompt(brief: brief(), transcript: ["Ozzy: Evening."],
                                    secondsToWrite: 30, elapsed: 30)
        #expect(!p.contains("STORY-EARNED COSTUME CHANGES"))
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

@MainActor
struct LiveReadingTests {
    let answer = """
    {"premise":"A neon-lit bedroom studio at 2am, three streamers between takes.",
     "cast":[{"name":"Wren","body":"alien","prompt":"runs the stream; never stops moving"},
             {"name":"Cass","body":"pink","prompt":"here for the snacks, says little"},
             {"name":"Ode","body":"orange","prompt":"explains things nobody asked about"}]}
    """

    @Test func aSceneAndACastAreReadFromTheSet() throws {
        let reading = try #require(LiveReading.parse(answer))
        #expect(reading.premise.contains("2am"))
        #expect(reading.cast.count == 3)
        #expect(reading.cast.map(\.name) == ["Wren", "Cass", "Ode"])
    }

    /// A body the catalog does not have used to cost us the whole person, which
    /// is how a cast of three quietly became a cast of one.
    @Test func anInventedBodyDoesNotCostUsThePerson() throws {
        let reading = try #require(LiveReading.parse("""
        {"premise":"x","cast":[{"name":"A","body":"banana","prompt":"p"},
                               {"name":"B","body":"alien","prompt":"q"}]}
        """))
        #expect(reading.cast.count == 2)
        #expect(reading.cast.map(\.name) == ["A", "B"])
        // The studio dresses the unknown one; the known one keeps what it said.
        let cast = reading.castMembers(mergingInto: [])
        #expect(cast.count == 2)
        #expect(cast[1].body == .alien)
    }

    /// However it arrived, the banny a new show opens with is not a company.
    @Test func thePlaceholderBannyIsNotACast() {
        for name in ["", "Banny", "Banny 1", "Banny 10", "banny 2"] {
            #expect(LiveCastMember(name: name, body: .orange).isPlaceholder,
                    "\"\(name)\" should not count as somebody the director cast")
        }
        // Anyone named, described or dressed is somebody's decision.
        #expect(!LiveCastMember(name: "Wren", body: .orange).isPlaceholder)
        #expect(!LiveCastMember(name: "Banny 1", body: .orange,
                                prompt: "the quiet one").isPlaceholder)
        #expect(!LiveCastMember(name: "Banny", body: .orange,
                                outfit: ["12": "chef-hat"]).isPlaceholder)
    }

    @Test func aReadingWithNobodyInItIsNoReading() {
        #expect(LiveReading.parse("""
        {"premise":"an empty room","cast":[]}
        """) == nil)
        #expect(LiveReading.parse("I could not open that image.") == nil)
    }

    /// Whatever the director already wrote outranks the reading.
    @Test func theDirectorsOwnWordsSurviveTheMerge() throws {
        let reading = try #require(LiveReading.parse(answer))
        let mine = [LiveCastMember(name: "Wren", body: .orange,
                                   outfit: ["12": "chef-hat"],
                                   prompt: "my own description",
                                   outfitIsChosen: true)]
        let merged = reading.castMembers(mergingInto: mine)
        let wren = try #require(merged.first { $0.name == "Wren" })
        #expect(wren.prompt == "my own description")
        #expect(wren.outfit == ["12": "chef-hat"])
        #expect(wren.outfitIsChosen)
        // And the ones it invented arrive whole.
        #expect(merged.first { $0.name == "Cass" }?.prompt.contains("snacks") == true)
    }

    @Test func aGivenPremiseIsKeptWordForWord() {
        let asked = LiveReading.prompt(imagePath: "/tmp/set.png", wanted: 3,
                                       premise: "A wake, badly attended.",
                                       wardrobe: ["12": ["chef-hat"],
                                                  "11": ["doc-coat"]])
        #expect(asked.contains("A wake, badly attended."))
        #expect(asked.contains("word for word"))
        #expect(asked.contains("Interpret the visible backdrop"))
        #expect(asked.contains("chef-hat"))
        #expect(asked.contains("\"outfit\""))
        // And with nothing given, it is asked to say what the place is.
        let blank = LiveReading.prompt(imagePath: "/tmp/set.png")
        #expect(blank.contains("playable two- or three-sentence scene premise"))
        #expect(blank.contains("what they specifically want"))
        #expect(blank.contains("what or who blocks them"))
        #expect(blank.contains("one dramatic question"))
        #expect(blank.contains("Do not merely say that people are talking"))
    }

    @Test func backdropOutfitsUseRealCatalogItemsAndSurviveIntoTheScene() throws {
        let reading = try #require(LiveReading.parse("""
        {"premise":"A kitchen during service.",
         "cast":[{"name":"Wren","body":"orange","prompt":"runs the pass",
                  "outfit":{"12":"chef-hat","11":"invented-coat"}}]}
        """))
        let cast = reading.castMembers(
            mergingInto: [], wardrobe: ["12": ["chef-hat"], "11": ["doc-coat"]])
        let wren = try #require(cast.first)
        #expect(wren.outfit == ["12": "chef-hat"])
        #expect(wren.outfitIsChosen)
    }

    @Test func revisingTheBriefRewritesTheSectionUnderReview() {
        var brief = LiveBrief(premise: "A bar.",
                              cast: [LiveCastMember(name: "A", body: .orange)])
        var doc = ShowDocument(stage: SceneState(
            characters: [Character(body: .orange, x: -0.2, name: "A", speed: 110)],
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))
        doc.stage.reactionLibrary = LiveReactionLibrary.standard
        let d = LiveDirector(brief: brief, document: doc, beats: { _ in [] })
        d.apply([.enters(who: "A", zone: .middle),
                 .line(who: "A", text: "Evening.", kind: .say)])
        #expect(!d.transcript.isEmpty)

        brief.premise = "A wake, badly attended."
        d.revise(brief)
        #expect(d.brief.premise == "A wake, badly attended.")
        #expect(d.transcript.isEmpty, "the section was written to a brief that no longer stands")
    }
}
