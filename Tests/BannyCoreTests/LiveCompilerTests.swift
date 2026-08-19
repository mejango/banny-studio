import Foundation
import Testing
@testable import BannyCore

/// The compiler owns everything a written script must not be trusted with.
/// These check the rules hold for any beats a model might produce.
struct LiveCompilerTests {
    func stage(_ names: [String]) -> ShowDocument {
        var d = ShowDocument(stage: SceneState(
            characters: names.map {
                Character(body: .orange, x: -0.2, name: $0, speed: 110)
            },
            // As LiveSceneBuilder builds it: a show needs its Scenes track.
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))
        d.stage.reactionLibrary = LiveReactionLibrary.standard
        // As LiveSceneBuilder sets it. Without wings the simulator clamps x to
        // 0.044, so anyone waiting offstage at -0.2 is dragged on stage and
        // every position after that disagrees with the compiler.
        d.stage.wings = 0.3
        return d
    }

    /// Two people in one zone must never share a silhouette — the complaint
    /// that started this: a pair standing almost exactly on top of each other.
    @Test func nobodyEverStandsInsideSomeoneElse() {
        for zone in [LiveZone.front, .middle, .far] {
            for n in 2...6 {
                let xs = LiveCompiler.positions(in: zone, count: n)
                let depths = (0..<n).map { LiveCompiler.depth(in: zone, index: $0) }
                for i in 0..<n {
                    for j in (i + 1)..<n {
                        let apart = abs(xs[i] - xs[j])
                        let layered = abs(depths[i] - depths[j])
                        #expect(apart >= LiveCompiler.minimumGap - 1e-9 || layered >= 0.04,
                                "\(zone) with \(n): \(i) and \(j) are \(apart) apart at the same depth")
                    }
                }
                // And nobody is pushed off the edge of the frame to achieve it.
                #expect(xs.allSatisfy { $0 > 0.02 && $0 < 0.98 }, "\(zone) with \(n): \(xs)")
            }
        }
    }

    @Test func neighboursInAZoneAreNeverAtTheSameDepth() {
        for zone in [LiveZone.front, .middle, .far] {
            for i in 0..<5 {
                #expect(LiveCompiler.depth(in: zone, index: i)
                        != LiveCompiler.depth(in: zone, index: i + 1))
            }
        }
    }

    @Test func aPairInAZoneIsAWholeBodyApart() {
        for zone in [LiveZone.front, .middle, .far] {
            let xs = LiveCompiler.positions(in: zone, count: 2)
            #expect(xs[1] - xs[0] >= LiveCompiler.minimumGap - 1e-9,
                    "\(zone): a pair only \(xs[1] - xs[0]) apart")
        }
    }

    @Test func everyPerformerIsDressed() {
        for n in 0..<12 {
            let outfit = LiveCastMember.defaultOutfit(n)
            #expect(!outfit.isEmpty, "cast member \(n) has nothing on")
            #expect(outfit.keys.allSatisfy { Int($0) != nil }, "slot keys must be numbers")
        }
    }

    @Test func zonesNeverOverlap() {
        for a in LiveZone.allCases where a != .offstage {
            for b in LiveZone.allCases where b != .offstage && b != a {
                let (lo, hi) = a.span.lowerBound < b.span.lowerBound ? (a, b) : (b, a)
                // Zones stay clear of each other by more than a body width, so
                // two groups never merge into one. Captions no longer need the
                // gap to be a full caption box wide: they follow their speaker
                // and the renderer stacks any that clash.
                #expect(hi.span.lowerBound - lo.span.upperBound
                        >= LiveCompiler.minimumGap - 1e-9)
            }
        }
    }

    @Test func aZoneIsSharedEvenlyHoweverManyAreInIt() {
        for n in 1...6 {
            let xs = LiveCompiler.positions(in: .middle, count: n)
            let span = LiveZone.middle.span
            #expect(xs.count == n)
            // A zone holds as many as fit a body apart; beyond that the group
            // spills either side rather than standing inside each other.
            let fits = Double(n - 1) * LiveCompiler.minimumGap
                <= span.upperBound - span.lowerBound + 1e-9
            if fits {
                #expect(xs.allSatisfy { $0 >= span.lowerBound - 1e-9
                                     && $0 <= span.upperBound + 1e-9 },
                        "\(n) in the middle zone: \(xs)")
            } else {
                let centre = (span.lowerBound + span.upperBound) / 2
                let mid = (xs.first! + xs.last!) / 2
                #expect(abs(mid - centre) < 0.06, "the crowd drifted off centre")
            }
            if n > 1 {
                let gaps = zip(xs, xs.dropFirst()).map { $1 - $0 }
                // Evenly, not bunched at one end.
                #expect(gaps.allSatisfy { abs($0 - gaps[0]) < 1e-9 })
            }
        }
    }

    @Test func aLineTimesItselfFromItsText() {
        let short = LiveCompiler.duration(of: "Hi.")
        let long = LiveCompiler.duration(of: String(repeating: "word ", count: 12))
        #expect(short < long)
        #expect(short >= 1.2)          // even two words need a beat to land
        #expect(long <= 8.0)           // never a monologue
    }

    /// Captions are read, not skimmed. Every one must stay up long enough for
    /// its length, and there must be a pause between turns.
    @Test func everyCaptionIsOnScreenLongEnoughToRead() {
        var doc = stage(["A", "B"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 21)
        let lines = ["Evening.",
                     "You are early, which for you is a kind of statement.",
                     "It also never asks about the divorce.",
                     "Fourteen is a good number. Fourteen has range."]
        var beats: [LiveBeat] = [.enters(who: "A", zone: .middle),
                                 .enters(who: "B", zone: .middle)]
        for (i, line) in lines.enumerated() {
            beats.append(.line(who: i.isMultiple(of: 2) ? "A" : "B",
                               text: line, kind: .say))
        }
        c.apply(beats, to: &doc, rng: &rng)

        let all = doc.stage.characters.flatMap(\.subs).sorted { $0.start < $1.start }
        #expect(all.count == lines.count)
        for cue in all {
            // No faster than a comfortable reading speed.
            let needed = Double(cue.text.count) / 10.0
            #expect(cue.dur >= needed,
                    "\"\(cue.text)\" is up for \(cue.dur)s, needs \(needed)s")
            #expect(cue.dur >= LiveCompiler.minimumCaptionOnScreen,
                    "\(cue.dur)s is a flash")
        }
        // And they do not tread on each other's heels.
        for (a, b) in zip(all, all.dropFirst()) {
            #expect(b.start > a.start + 1.0,
                    "lines \(a.start) and \(b.start) are too close together")
        }
    }

    @Test func everyArrowPressIsReleased() {
        var doc = stage(["A", "B", "C"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 7)
        c.apply([
            .enters(who: "A", zone: .middle), .enters(who: "B", zone: .middle),
            .enters(who: "C", zone: .front),
            .line(who: "A", text: "Is anyone else early?", kind: .say),
            .line(who: "B", text: "Everyone is early. That is the problem.", kind: .say),
            .move(who: "B", zone: .front),
            .line(who: "C", text: "Not me.", kind: .cut),
            .exits(who: "A"),
        ], to: &doc, rng: &rng)

        for character in doc.stage.characters {
            var held: Set<EventCode> = []
            for case let .key(_, code, down) in character.events
            where [.arrowLeft, .arrowRight, .arrowUp, .arrowDown].contains(code) {
                if down {
                    #expect(!held.contains(code))    // never pressed twice
                    held.insert(code)
                } else {
                    #expect(held.contains(code))     // never released unpressed
                    held.remove(code)
                }
            }
            #expect(held.isEmpty)                    // nothing left held
        }
    }

    @Test func aPivotNeverLandsInsideAWalk() {
        var doc = stage(["A", "B"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 11)
        c.apply([
            .enters(who: "A", zone: .middle), .enters(who: "B", zone: .middle),
            .line(who: "A", text: "Where were you?", kind: .say),
            .move(who: "A", zone: .far),
            .line(who: "B", text: "Right behind you the whole time.", kind: .say),
            .line(who: "A", text: "You were not.", kind: .say),
        ], to: &doc, rng: &rng)

        for character in doc.stage.characters {
            // Reconstruct walks (long holds) and pivots (taps) and check they
            // never overlap: a pivot's key-up would release the walk.
            var open: [EventCode: Double] = [:]
            var spans: [(Double, Double)] = []
            for case let .key(t, code, down) in character.events
            where code == .arrowLeft || code == .arrowRight {
                if down { open[code] = t }
                else if let s = open.removeValue(forKey: code) { spans.append((s, t)) }
            }
            let walks = spans.filter { $0.1 - $0.0 > 0.2 }
            let pivots = spans.filter { $0.1 - $0.0 <= 0.2 }
            for p in pivots {
                for w in walks {
                    #expect(!(p.0 <= w.1 && p.1 >= w.0))
                }
            }
        }
    }

    @Test func captionsAreAnchoredOverTheirSpeaker() {
        var doc = stage(["A", "B"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 3)
        c.apply([
            .enters(who: "A", zone: .front), .enters(who: "B", zone: .far),
            .line(who: "A", text: "Over here.", kind: .say),
            .line(who: "B", text: "And over here.", kind: .say),
        ], to: &doc, rng: &rng)
        // Captions follow the live pose, so what matters here is that each
        // speaker ends up in their own zone and the two are far enough apart to
        // read as separate conversations. Where the box lands is the renderer's
        // job, covered by FollowingCaptionTests.
        #expect(doc.stage.characters.allSatisfy { $0.subs.first?.follow == true })
        let sim = SceneSimulator(state: doc.stage)
        let ax = sim.pose(characterIndex: 0, at: c.now).x
        let bx = sim.pose(characterIndex: 1, at: c.now).x
        #expect(abs(ax - bx) >= 0.20, "A at \(ax), B at \(bx) — too close to tell apart")
    }

    @Test func aSilentSceneStillProducesAValidDocument() {
        var doc = stage(["A"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 1)
        // A hold is capped at 2.5s, so four of them make the four seconds.
        c.apply([.enters(who: "A", zone: .middle)] + Array(repeating: .hold(seconds: 3), count: 4),
                to: &doc, rng: &rng)
        #expect(doc.stage.characters[0].subs.isEmpty)
        #expect(c.now >= 4)
    }

    @Test func beatsForUnknownPerformersAreIgnored() {
        var doc = stage(["A"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 5)
        c.apply([.line(who: "Nobody", text: "hello?", kind: .say)], to: &doc, rng: &rng)
        #expect(doc.stage.characters[0].subs.isEmpty)
    }

    @Test func mouthStatesAreNeverShorterThanTwoFrames() {
        var doc = stage(["A"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 9)
        c.apply([.enters(who: "A", zone: .middle),
                 .line(who: "A", text: String(repeating: "talking ", count: 8),
                       kind: .say)], to: &doc, rng: &rng)
        var open: Double?
        for case let .key(t, code, down) in doc.stage.characters[0].events
        where code == .keyM {
            if down { open = t }
            else if let s = open { #expect(t - s >= LiveCompiler.minMouthState - 1e-9); open = nil }
        }
    }

    /// Command-line agents print a braced banner before they answer, and chat
    /// models wrap the answer in prose or a fence. Taking the first `{` would
    /// swallow the banner and fail.
    @Test func theAnswerIsFoundPastWhateverElseWasPrinted() throws {
        let answer = #"{"beats":[{"beat":"line","who":"A","text":"Hi.","kind":"say"}]}"#
        let noise = [
            answer,
            "```json\n\(answer)\n```",
            "Here you go:\n\(answer)\nHope that helps.",
            "{\"session\":\"01a0\",\"model\":\"gpt\"}\n--------\n\(answer)",
            "config: {\"approval\":\"on-request\"}\nthinking...\n\(answer)\ndone",
        ]
        for text in noise {
            let beats = try LiveBeatBatch.parse(text)
            #expect(beats.count == 1, "failed on: \(text.prefix(40))")
        }
        #expect(throws: LiveModelError.self) {
            try LiveBeatBatch.parse("I could not do that. {\"error\":\"nope\"}")
        }
    }

    @Test func theSameSeedReplaysIdentically() {
        let beats: [LiveBeat] = [.enters(who: "A", zone: .middle),
                                 .enters(who: "B", zone: .middle),
                                 .line(who: "A", text: "Say that again.", kind: .say),
                                 .line(who: "B", text: "I will not.", kind: .say)]
        func run() -> ShowDocument {
            var d = stage(["A", "B"])
            var c = LiveCompiler(document: d)
            var r = LiveRandom(seed: 42)
            c.apply(beats, to: &d, rng: &r)
            return d
        }
        #expect(run() == run())
    }
}

extension LiveCompilerTests {
    /// Whoever is left closes ranks: a two-hander that loses one performer must
    /// not leave the survivor stranded at their half of the zone.
    @Test func theGroupClosesRanksWhenSomeoneLeaves() {
        var doc = stage(["A", "B"])
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 7)
        c.apply([.enters(who: "A", zone: .middle),
                 .enters(who: "B", zone: .middle),
                 .hold(seconds: 2),
                 .exits(who: "A"),
                 // Enough time for B to finish closing ranks before we look.
                 .hold(seconds: 3), .hold(seconds: 3), .hold(seconds: 3),
                 .line(who: "B", text: "Well then.", kind: .say)], to: &doc, rng: &rng)
        // Ask the simulator where B actually ends up, rather than reading it off
        // a caption — captions follow the live pose now and record no position.
        let x = SceneSimulator(state: doc.stage).pose(characterIndex: 1, at: c.now).x
        let centre = (LiveZone.middle.span.lowerBound + LiveZone.middle.span.upperBound) / 2
        #expect(abs(x - centre) < 0.03, "B stayed at \(x) instead of closing to \(centre)")
    }

    /// End to end: a scripted batch, compiled exactly as Live mode compiles a
    /// model's answer. Set LIVE_DEMO_OUT to a .bs path to emit the package for
    /// `banny validate` and `banny preview`.
    @Test func aCompiledLiveSceneIsAShippableDocument() throws {
        var doc = stage(["Ozzy", "Rue", "Vic", "Moss", "Bex", "Tull"])
        doc.stage.wings = 0.3
        doc.stage.gSize = 1.7          // as Live mode stages it
        var c = LiveCompiler(document: doc)
        var rng = LiveRandom(seed: 20260814)
        c.apply([
            .enters(who: "Ozzy", zone: .middle),
            .line(who: "Ozzy", text: "You are the first one here.", kind: .say),
            .enters(who: "Rue", zone: .middle),
            .line(who: "Rue", text: "I am always the first one here.", kind: .say),
            .gesture(who: "Ozzy", name: "nod"),
            .enters(who: "Vic", zone: .front),
            .enters(who: "Moss", zone: .middle),
            .enters(who: "Bex", zone: .far),
            .enters(who: "Tull", zone: .far),
            .line(who: "Vic", text: "That is not a boast.", kind: .cut),
            .line(who: "Rue", text: "It was not offered as one.", kind: .say),
            .gesture(who: "Ozzy", name: "bellylaugh"),
            .move(who: "Ozzy", zone: .front),
            .line(who: "Ozzy", text: "Drink?", kind: .quiet),
            .hold(seconds: 3),
            .exits(who: "Rue"),
            .line(who: "Vic", text: "He will be back.", kind: .say),
        ], to: &doc, rng: &rng)

        doc.show = [ShowSegment(name: "Live", from: 0, to: c.now + 2)]
        #expect(c.now > 10)
        // Everyone given a line is captioned; the silent extras are not.
        let spoke = ["Ozzy", "Rue", "Vic"]
        #expect(doc.stage.characters.filter { spoke.contains($0.name) }
            .allSatisfy { !$0.subs.isEmpty })

        let data = try JSONEncoder().encode(doc)
        #expect((try? JSONDecoder().decode(ShowDocument.self, from: data)) != nil)

        if let out = ProcessInfo.processInfo.environment["LIVE_DEMO_OUT"] {
            let dir = URL(fileURLWithPath: out)
            for sub in ["assets", "audio"] {
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            try data.write(to: dir.appendingPathComponent("show.json"))
        }
    }
}
