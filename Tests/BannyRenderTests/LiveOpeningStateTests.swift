import Foundation
import Testing
@testable import BannyCore
@testable import BannyRender

/// The app's live scenes start from a document the SPM tests never built: every
/// performer hidden at t=0 with a recorded start pose, exactly as
/// LiveSceneBuilder makes it. These check a section written onto *that* is
/// actually visible — the whole section came up empty otherwise.
struct LiveOpeningStateTests {
    /// LiveSceneBuilder's opening document, minus the backdrop.
    func opening(_ names: [String]) -> ShowDocument {
        var d = ShowDocument(stage: SceneState(
            characters: names.enumerated().map { i, name in
                let wing = i.isMultiple(of: 2) ? -0.2 : 1.2
                var c = Character(body: .orange, x: wing, depth: 0.06, size: 1,
                                  face: i.isMultiple(of: 2) ? 1 : -1,
                                  name: name, speed: 110)
                c.baseOutfit = Dictionary(uniqueKeysWithValues:
                    LiveCastMember.defaultOutfit(i).compactMap { key, value in
                        Int(key).map { ($0, value) }
                    })
                c.presence = [VisibilityEvent(t: 0, visible: false)]
                c.recStart = StartPose(x: wing, depth: 0.06,
                                       face: i.isMultiple(of: 2) ? 1 : -1)
                return c
            },
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))
        d.stage.reactionLibrary = LiveReactionLibrary.standard
        d.stage.wings = 0.3
        d.stage.gSize = 1.7
        d.show = [ShowSegment(name: "Live scene", from: 0, to: 24 * 60 * 60)]
        return d
    }

    func performed() -> ShowDocument {
        var doc = opening(["Ozzy", "Rue", "Vic"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 5)
        c.apply([
            .enters(who: "Ozzy", zone: .middle),
            .line(who: "Ozzy", text: "You are the first one here.", kind: .say),
            .enters(who: "Rue", zone: .middle),
            .line(who: "Rue", text: "I am always the first one here.", kind: .say),
            .enters(who: "Vic", zone: .front),
            .line(who: "Vic", text: "That is not a boast.", kind: .say),
        ], to: &doc, rng: &rng)
        return doc
    }

    @Test func everyoneWhoEntersBecomesVisible() {
        let doc = performed()
        for character in doc.stage.characters {
            // Somewhere after their entrance they must be on screen.
            let shown = (0...40).map { Double($0) }
                .contains { character.presence.opacity(at: $0) > 0.5 }
            #expect(shown, "\(character.name) is never visible")
        }
    }

    @Test func aRecordedStartPoseDoesNotOverrideTheWalkOnstage() {
        let doc = performed()
        let sim = SceneSimulator(state: doc.stage)
        for (i, character) in doc.stage.characters.enumerated() {
            // By the end of the section everyone should have walked into frame.
            let x = sim.pose(characterIndex: i, at: 30).x
            #expect(x > 0.0 && x < 1.0,
                    "\(character.name) never made it on stage — x \(x)")
        }
    }

    @Test func somebodyIsOnStageForMostOfTheSection() {
        let doc = performed()
        let sim = SceneSimulator(state: doc.stage)
        var visibleSeconds = 0
        for t in stride(from: 2.0, through: 30.0, by: 1.0) {
            let anyone = doc.stage.characters.indices.contains { i in
                let onScreen = (0.0...1.0).contains(sim.pose(characterIndex: i, at: t).x)
                return onScreen && doc.stage.characters[i].presence.opacity(at: t) > 0.5
            }
            if anyone { visibleSeconds += 1 }
        }
        #expect(visibleSeconds > 20,
                "the stage was empty for all but \(visibleSeconds)s of the section")
    }

    /// A script that never writes an entrance still has to produce a scene.
    /// Dropping those lines left an empty room for the whole section.
    @Test func aLineWithNoEntranceStillPutsThemOnStage() {
        var doc = opening(["Ozzy", "Rue"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 9)
        c.apply([
            .line(who: "Ozzy", text: "Evening.", kind: .say),
            .line(who: "Rue", text: "You are early.", kind: .say),
            .hold(seconds: 3),
        ], to: &doc, rng: &rng)

        let cues = doc.stage.characters.flatMap(\.subs)
        #expect(cues.count == 2, "dialogue was dropped for want of an entrance")

        let sim = SceneSimulator(state: doc.stage)
        for (i, character) in doc.stage.characters.enumerated() {
            let onScreen = (0.0...1.0).contains(sim.pose(characterIndex: i, at: c.now).x)
            let lit = character.presence.opacity(at: c.now) > 0.5
            #expect(onScreen && lit, "\(character.name) never appeared")
        }
    }

    /// Speech pauses make captions readable but leave a room of statues. Nobody
    /// on stage should be motionless for long.
    @Test func nobodyStandsFrozenForMoreThanAFewSeconds() {
        var doc = opening(["Ozzy", "Rue"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 4)
        c.apply([
            .enters(who: "Ozzy", zone: .middle),
            .enters(who: "Rue", zone: .middle),
            .line(who: "Ozzy", text: "Evening.", kind: .say),
            .hold(seconds: 2),
            .line(who: "Rue", text: "You are early, as ever.", kind: .say),
            .hold(seconds: 2),
            .line(who: "Ozzy", text: "The bus was kind to me.", kind: .say),
        ], to: &doc, rng: &rng)

        for character in doc.stage.characters {
            // When is this performer doing anything at all?
            var spans: [(Double, Double)] = character.reactions.map {
                ($0.start, $0.start + $0.dur)
            }
            spans += character.subs.map { ($0.start, $0.start + $0.dur) }
            var open: [EventCode: Double] = [:]
            for case let .key(t, code, down) in character.events {
                if down { open[code] = t }
                else if let s = open.removeValue(forKey: code) { spans.append((s, t)) }
            }
            spans.sort { $0.0 < $1.0 }

            let arrived = character.presence.filter(\.visible).map(\.t).min() ?? 0
            var cursor = arrived
            var worst = 0.0
            for span in spans where span.0 > cursor {
                worst = max(worst, span.0 - cursor)
                cursor = max(cursor, span.1)
            }
            worst = max(worst, c.now - cursor)
            #expect(worst <= LiveCompiler.idleLimit + 2.5,
                    "\(character.name) stood still for \(worst)s")
        }
    }

    /// Trading lines is what makes one conversation; standing in two huddles
    /// while doing it reads as two, whatever the dialogue says.
    @Test func answeringSomebodyPutsYouInTheirGroup() {
        var doc = opening(["Ozzy", "Rue", "Vic"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 11)
        c.apply([
            .enters(who: "Ozzy", zone: .front),
            .enters(who: "Rue", zone: .far),      // deliberately far apart
            .line(who: "Ozzy", text: "You made it, then.", kind: .say),
            .line(who: "Rue", text: "Too late, apparently.", kind: .say),
            .line(who: "Ozzy", text: "Not at all.", kind: .say),
        ], to: &doc, rng: &rng)

        let sim = SceneSimulator(state: doc.stage)
        let ozzy = sim.pose(characterIndex: 0, at: c.now).x
        let rue = sim.pose(characterIndex: 1, at: c.now).x
        #expect(abs(ozzy - rue) < 0.45,
                "two people in one exchange ended \(abs(ozzy - rue)) apart")

        // And they are looking at each other, not past one another. Sampled a
        // moment after the batch ends: a pivot takes a beat to land.
        let settled = c.now + 1.5
        let ozzyFace = sim.pose(characterIndex: 0, at: settled).face
        let rueFace = sim.pose(characterIndex: 1, at: settled).face
        if ozzy < rue {
            #expect(ozzyFace > 0 && rueFace < 0, "they are facing away from each other")
        } else {
            #expect(ozzyFace < 0 && rueFace > 0, "they are facing away from each other")
        }
    }

    /// Fuzzing somebody in or out mid-conversation is the invasive version of
    /// the effect. It is only ever allowed when nobody is standing with them.
    @Test func nobodyIsFuzzedInOrOutWhileStandingWithSomeone() {
        var doc = opening(["Ozzy", "Rue", "Vic"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 6)
        c.apply([
            .enters(who: "Ozzy", zone: .middle),
            .enters(who: "Rue", zone: .middle),
            .line(who: "Ozzy", text: "Evening.", kind: .say),
            .enters(who: "Vic", zone: .middle),
            .line(who: "Rue", text: "And there he is.", kind: .say),
            .exits(who: "Vic"),
            .exits(who: "Rue"),
            .exits(who: "Ozzy"),
        ], to: &doc, rng: &rng)

        let sim = SceneSimulator(state: doc.stage)
        for (i, character) in doc.stage.characters.enumerated() {
            for event in character.presence where (event.fade ?? 0) > 0 {
                // Who else was on screen, in the same part of the room, as this
                // performer appeared or vanished?
                let mine = sim.pose(characterIndex: i, at: event.t).x
                for (j, other) in doc.stage.characters.enumerated() where j != i {
                    guard other.presence.opacity(at: event.t) > 0.5 else { continue }
                    let theirs = sim.pose(characterIndex: j, at: event.t).x
                    #expect(abs(mine - theirs) > 0.3,
                            "\(character.name) fuzzed at \(event.t) beside \(other.name)")
                }
            }
        }
    }

    @Test func captionsExistAndAreAnchoredOnScreen() {
        let doc = performed()
        let cues = doc.stage.characters.flatMap(\.subs)
        #expect(cues.count == 3)
        #expect(cues.allSatisfy { $0.follow == true })
    }
}

/// Leaning is the scene's loudest gesture, so it has to stay rare and mean
/// something. These pin down when a performer is allowed off the vertical.
struct LiveTiltTests {
    /// Every gesture that moves someone off the vertical.
    static let leaning = Set(["secret", "bellylaugh", "recoil", "nod", "hesitate"])

    func opening(_ names: [String]) -> ShowDocument {
        var d = ShowDocument(stage: SceneState(
            characters: names.enumerated().map { i, name in
                let wing = i.isMultiple(of: 2) ? -0.2 : 1.2
                var c = Character(body: .orange, x: wing, depth: 0.06, size: 1,
                                  face: i.isMultiple(of: 2) ? 1 : -1,
                                  name: name, speed: 110)
                c.presence = [VisibilityEvent(t: 0, visible: false)]
                return c
            },
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))
        d.stage.reactionLibrary = LiveReactionLibrary.standard
        d.stage.wings = 0.3
        return d
    }

    func leans(in doc: ShowDocument) -> [ReactionInstance] {
        doc.stage.characters.flatMap(\.reactions)
            .filter { LiveTiltTests.leaning.contains($0.reactionID) }
    }

    @Test func idleBusinessNeverLeans() {
        var doc = opening(["A", "B"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 3)
        // A long stretch of plain talk: all the gaps get filled with business.
        var beats: [LiveBeat] = [.enters(who: "A", zone: .middle),
                                 .enters(who: "B", zone: .middle)]
        for i in 0..<10 {
            beats.append(.line(who: i.isMultiple(of: 2) ? "A" : "B",
                               text: "An ordinary remark about the weather.", kind: .say))
            beats.append(.hold(seconds: 2))
        }
        c.apply(beats, to: &doc, rng: &rng)

        let all = doc.stage.characters.flatMap(\.reactions)
        #expect(all.count > 8, "no business at all was added")
        // Nods are allowed as agreement, but nothing else leans in plain talk.
        let heavy = leans(in: doc).filter { $0.reactionID != "nod" }
        #expect(heavy.isEmpty,
                "plain conversation produced leans: \(heavy.map(\.reactionID))")
    }

    @Test func aConfidenceLeansIn() {
        var doc = opening(["A", "B"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 3)
        c.apply([.enters(who: "A", zone: .middle), .enters(who: "B", zone: .middle),
                 .line(who: "A", text: "Do not repeat this.", kind: .quiet)],
                to: &doc, rng: &rng)
        #expect(leans(in: doc).contains { $0.reactionID == "secret" },
                "a confidence did not lean in")
    }

    @Test func theRoomRocksBackAtALaugh() {
        var doc = opening(["A", "B"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 3)
        c.apply([.enters(who: "A", zone: .middle), .enters(who: "B", zone: .middle),
                 .line(who: "A", text: "So he brings the whole thing back.", kind: .laugh)],
                to: &doc, rng: &rng)
        #expect(leans(in: doc).contains { $0.reactionID == "bellylaugh" },
                "nobody rocked back at the laugh")
    }

    /// Sparingly, measured: leaning is a small fraction of what a scene does.
    @Test func leansStayRareAcrossAWholeSection() {
        var doc = opening(["A", "B", "C"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 8)
        var beats: [LiveBeat] = [.enters(who: "A", zone: .middle),
                                 .enters(who: "B", zone: .middle),
                                 .enters(who: "C", zone: .middle)]
        let kinds: [LiveLineKind] = [.say, .say, .say, .say, .quiet, .say, .say, .laugh]
        for (i, kind) in kinds.enumerated() {
            beats.append(.line(who: ["A", "B", "C"][i % 3],
                               text: "Something worth saying out loud.", kind: kind))
        }
        c.apply(beats, to: &doc, rng: &rng)

        let all = doc.stage.characters.flatMap(\.reactions)
        let leaning = leans(in: doc)
        #expect(Double(leaning.count) / Double(all.count) < 0.35,
                "\(leaning.count) of \(all.count) gestures were leans")
    }
}
