import Foundation
import Testing
@testable import BannyCore

private func makeScene(_ character: Character, gravity: Double = 1) -> SceneState {
    SceneState(characters: [character], gravity: gravity)
}

@Test(.enabled(if: ep1Exists)) func fullStateMatchesGoldenOnEp1() throws {
    let golden = try loadGolden()
    let ep1 = try loadEp1V1()
    for scene in golden.scenes {
        let chars = try #require(ep1[scene.id])
        for gc in scene.characters {
            let (name, events, recStart) = chars[gc.index]
            let c = Character(body: .orange, baseOutfit: [:], events: events, name: name, recStart: recStart)
            let sim = SceneSimulator(state: SceneState(characters: [c], gScale: scene.gScale))
            for s in gc.samples {
                let pose = sim.pose(characterIndex: 0, at: s.t)
                #expect(pose.eye.rawValue == s.eye, "\(gc.name) eye at t=\(s.t)")
                #expect(pose.tilt == s.tilt, "\(gc.name) tilt at t=\(s.t)")
                #expect(pose.talking == s.talking, "\(gc.name) talking at t=\(s.t)")
                #expect(abs(pose.x - s.x) < 1e-9)
                #expect(abs(pose.depth - s.depth) < 1e-9)
            }
        }
    }
}

@Test func outfitChangeDissolvesOverWindow() {
    // Add an outfit to slot 11 at t=1; it dissolves over the next 0.8s.
    let c = Character(body: .orange, events: [.outfit(t: 1, slot: 11, name: "doc-coat")])
    let sim = SceneSimulator(state: makeScene(c))

    // Before the change: nothing on slot 11, no animation.
    #expect(sim.pose(characterIndex: 0, at: 0.5).outfit[11] == nil)
    #expect(sim.pose(characterIndex: 0, at: 0.5).outfitAnim[11] == nil)

    // Mid-dissolve (0.2s into a 0.4s window): new item resolved, animating.
    let mid = sim.pose(characterIndex: 0, at: 1.2)
    #expect(mid.outfit[11] == "doc-coat")
    let a = try! #require(mid.outfitAnim[11])
    #expect(a.prev == nil)                       // slot was empty → pure reveal
    #expect(abs(a.progress - 0.5) < 0.05)        // 0.2s of 0.4s

    // After the window: settled, no animation.
    #expect(sim.pose(characterIndex: 0, at: 1.6).outfitAnim[11] == nil)
    #expect(sim.pose(characterIndex: 0, at: 1.6).outfit[11] == "doc-coat")

    // Swap keeps the outgoing item as `prev` for the crossfade.
    let c2 = Character(body: .orange, baseOutfit: [11: "doc-coat"],
                       events: [.outfit(t: 1, slot: 11, name: "overalls")])
    let sim2 = SceneSimulator(state: makeScene(c2))
    let swap = sim2.pose(characterIndex: 0, at: 1.1)
    #expect(swap.outfit[11] == "overalls")
    #expect(swap.outfitAnim[11]?.prev == "doc-coat")
}

@Test func tiltEasesButInstantValueStaysExact() {
    // keyT down at t=1 → instant tilt jumps to 9, but leanTilt eases in.
    let c = Character(body: .orange, events: [.key(t: 1, code: .keyT, down: true)])
    let sim = SceneSimulator(state: makeScene(c))
    let mid = sim.pose(characterIndex: 0, at: 1.05)   // 0.05s into a 0.15s ease
    #expect(mid.tilt == 9)                             // instant value exact (fidelity)
    #expect(mid.leanTilt > 0 && mid.leanTilt < 9)      // render lean still ramping
    let settled = sim.pose(characterIndex: 0, at: 1.3)
    #expect(settled.tilt == 9 && abs(settled.leanTilt - 9) < 1e-9)
}

@Test func jumpWindowFollowsGravity() {
    let c = Character(body: .pink, events: [.key(t: 1, code: .keyJ, down: true)])
    // gravity 1 → dur 460 ms, height 30
    let sim = SceneSimulator(state: makeScene(c, gravity: 1))
    let mid = sim.pose(characterIndex: 0, at: 1.2).jump
    #expect(abs((mid?.progress ?? -1) - 0.2 / 0.46) < 1e-9)
    #expect(mid?.height == 30)
    #expect(sim.pose(characterIndex: 0, at: 1.5).jump == nil)
    #expect(sim.pose(characterIndex: 0, at: 0.9).jump == nil)
    // gravity 2 → dur 230 ms, height 15: over by t=1.25
    let fast = SceneSimulator(state: makeScene(c, gravity: 2))
    #expect(fast.pose(characterIndex: 0, at: 1.25).jump == nil)
    let fastMid = fast.pose(characterIndex: 0, at: 1.1).jump
    #expect(abs((fastMid?.progress ?? -1) - 0.1 / 0.23) < 1e-9)
    #expect(fastMid?.height == 15)
}

@Test func lowGravityActionsExposeTheirFullLandingWindow() {
    let gravity = 0.3
    #expect(SceneSimulator.jumpDuration(gravity: gravity) > 1.5)
    #expect(SceneSimulator.flipDuration(gravity: gravity) == 2.4)

    let character = Character(body: .orange, events: [
        .key(t: 0, code: .keyF, down: true),
        .key(t: 0.08, code: .keyF, down: false),
    ])
    let simulator = SceneSimulator(state: makeScene(character, gravity: gravity))
    let nearLanding = try! #require(simulator.pose(characterIndex: 0, at: 2.39).flip)
    #expect(nearLanding.progress > 0.99)
    #expect(abs(nearLanding.rotation) > 359)
    #expect(simulator.pose(characterIndex: 0, at: 2.4).flip == nil)
}

@Test func frontAndBackFlipsCompleteAStylizedDeterministicArc() {
    let character = Character(body: .orange, events: [
        .key(t: 1, code: .keyF, down: true),
        .key(t: 1.08, code: .keyF, down: false),
        .key(t: 2, code: .keyD, down: true),
        .key(t: 2.08, code: .keyD, down: false),
    ])
    let scene = makeScene(character)
    let simulator = SceneSimulator(state: scene)
    func expectedRotation(at progress: Double, direction: Double = 1) -> Double {
        direction * 360 * SceneSimulator.flipRotationFactor(progress: progress)
    }

    #expect(simulator.pose(characterIndex: 0, at: 0.9).flip == nil)
    let launch = try! #require(simulator.pose(characterIndex: 0, at: 1.072).flip)
    #expect(abs(launch.progress - 0.1) < 1e-9)
    #expect(abs(launch.rotation - expectedRotation(at: 0.1)) < 1e-9)
    #expect(launch.rotation > 10 && launch.rotation < 20) // turn blends into lift

    let front = try! #require(simulator.pose(characterIndex: 0, at: 1.36).flip)
    #expect(abs(front.progress - 0.5) < 1e-9)
    #expect(abs(front.rotation - expectedRotation(at: 0.5)) < 1e-9)
    #expect(front.height == 60)

    let landing = try! #require(simulator.pose(characterIndex: 0, at: 1.648).flip)
    #expect(abs(landing.progress - 0.9) < 1e-9)
    #expect(abs(landing.rotation - expectedRotation(at: 0.9)) < 1e-9)
    #expect(landing.rotation > 350 && landing.rotation < 358)
    let followThrough = try! #require(simulator.pose(characterIndex: 0, at: 1.684).flip)
    #expect(abs(followThrough.progress - 0.95) < 1e-9)
    #expect(followThrough.rotation > landing.rotation)
    #expect(followThrough.rotation < 360) // keep turning through the steep drop
    #expect(simulator.pose(characterIndex: 0, at: 1.721).flip == nil)

    let back = try! #require(simulator.pose(characterIndex: 0, at: 2.36).flip)
    #expect(abs(back.progress - 0.5) < 1e-9)
    #expect(abs(back.rotation - expectedRotation(at: 0.5, direction: -1)) < 1e-9)
}

@Test func outfitResolvesTimedChanges() {
    let c = Character(body: .orange,
                      baseOutfit: [12: "proff-hair", 6: "nerd"],
                      events: [
                        .outfit(t: 2, slot: 12, name: "chef-hat"),
                        .outfit(t: 4, slot: 6, name: nil),
                      ])
    let sim = SceneSimulator(state: makeScene(c))
    #expect(sim.pose(characterIndex: 0, at: 1).outfit == [12: "proff-hair", 6: "nerd"])
    #expect(sim.pose(characterIndex: 0, at: 3).outfit == [12: "chef-hat", 6: "nerd"])
    #expect(sim.pose(characterIndex: 0, at: 5).outfit == [12: "chef-hat"])
}

@Test func latestStartingSubtitleWins() {
    let c = Character(body: .alien, subs: [
        Subtitle(text: "first", start: 0, dur: 10),
        Subtitle(text: "second", start: 3, dur: 2),
    ])
    let sim = SceneSimulator(state: makeScene(c))
    #expect(sim.pose(characterIndex: 0, at: 1).activeSubtitle == "first")
    #expect(sim.pose(characterIndex: 0, at: 4).activeSubtitle == "second")
    #expect(sim.pose(characterIndex: 0, at: 6).activeSubtitle == "first")
    #expect(sim.pose(characterIndex: 0, at: 11).activeSubtitle == nil)
}

@Test func reactionBlocksTimeStretchAndTemporarilyOwnOutfitSlots() {
    let reaction = ReactionDefinition(id: "shock", name: "Shock", dur: 2, events: [
        .key(t: 0.2, code: .keyM, down: true),
        .outfit(t: 0.5, slot: 12, name: "chef-hat"),
        .key(t: 0.8, code: .keyM, down: false),
    ])
    let block = ReactionInstance(id: "shock-1", reactionID: reaction.id,
                                 start: 10, dur: 4)
    let character = Character(body: .orange, baseOutfit: [6: "nerd"],
                              reactions: [block])
    let sim = SceneSimulator(state: SceneState(characters: [character],
                                               reactionLibrary: [reaction]))

    // 2x timeline stretch: local 0.2/0.5/0.8 happen at 10.4/11/11.6.
    let speaking = sim.pose(characterIndex: 0, at: 10.6)
    #expect(speaking.talking)
    #expect(speaking.outfit == [6: "nerd"])
    let dressed = sim.pose(characterIndex: 0, at: 11.2)
    #expect(dressed.talking)
    #expect(dressed.outfit[6] == "nerd")
    #expect(dressed.outfit[12] == "chef-hat")
    #expect(!sim.pose(characterIndex: 0, at: 12).talking)

    // The reaction owns slot 12 only while its block is active.
    let after = sim.pose(characterIndex: 0, at: 14)
    #expect(after.outfit == [6: "nerd"])
}

@Test func reactionIntensityScalesRelativeMotionAndUnderlyingStateResumes() {
    let spin = ReactionDefinition(id: "spin", name: "Spin", dur: 1, events: [
        .key(t: 0, code: .rotateRight, down: true),
        .key(t: 1, code: .rotateRight, down: false),
    ])
    let blink = ReactionDefinition(id: "blink", name: "Blink", dur: 1, events: [
        .key(t: 0, code: .comma, down: true),
        .key(t: 1, code: .comma, down: false),
    ])
    let character = Character(
        body: .pink,
        events: [.key(t: 0, code: .keyM, down: true)],
        reactions: [
            ReactionInstance(id: "s", reactionID: "spin", start: 2, dur: 1,
                             intensity: 2),
            ReactionInstance(id: "b", reactionID: "blink", start: 2, dur: 1),
        ],
        recStart: StartPose(x: 0.4, depth: 0, face: 1, spin: 30, zoom: 1),
        rotationSpeed: 90)
    let sim = SceneSimulator(state: SceneState(characters: [character],
                                               reactionLibrary: [spin, blink]))
    let active = sim.pose(characterIndex: 0, at: 2.5)
    #expect(active.spin > 100 && active.spin < 125)
    #expect(active.eye == .closed)
    #expect(active.talking) // blink reaction does not own the talk channel

    let after = sim.pose(characterIndex: 0, at: 3)
    #expect(abs(after.spin - 30) < 0.01)
    #expect(after.eye == .open)
    #expect(after.talking)
}

@Test func reactionMotionEventsTemporarilyOwnBodySizeAndWobble() {
    let definition = ReactionDefinition(id: "squash", name: "Squash", dur: 1, events: [
        .motion(t: 0.1, speed: nil, rotationSpeed: nil, wobble: 3, size: 0.5),
    ])
    let character = Character(body: .orange, reactions: [
        ReactionInstance(id: "sq", reactionID: "squash", start: 1, dur: 1,
                         intensity: 0.5),
    ], wobble: 7)
    let sim = SceneSimulator(state: SceneState(characters: [character],
                                               reactionLibrary: [definition]))
    let active = sim.pose(characterIndex: 0, at: 1.5)
    #expect(abs(active.size - 0.75) < 1e-9)
    #expect(abs(active.wobble - 5) < 1e-9)
    let after = sim.pose(characterIndex: 0, at: 2)
    #expect(after.size == 1)
    #expect(after.wobble == 7)
}

@Test(.enabled(if: ep1Exists)) func poseQueryFastEnough() throws {
    let ep1 = try loadEp1V1()
    let darl = ep1.values.flatMap { $0 }.max { $0.events.count < $1.events.count }!
    #expect(darl.events.count >= 900)
    let c = Character(body: .orange, events: darl.events, recStart: darl.recStart)
    let sim = SceneSimulator(state: SceneState(characters: [c], gScale: 0.92))
    let t0 = ContinuousClock.now
    _ = sim.pose(characterIndex: 0, at: 30)
    let elapsed = ContinuousClock.now - t0
    #expect(elapsed < .milliseconds(5), "pose query took \(elapsed)")
}
