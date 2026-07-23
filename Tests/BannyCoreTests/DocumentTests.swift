import Foundation
import Testing
@testable import BannyCore

@Test func documentRoundTrip() throws {
    let doc = ShowDocument(
        stage: SceneState(
            characters: [Character(
                body: .orange, x: 0.4, depth: 0.2, face: -1,
                baseOutfit: [5: "fierce", 11: "doc-coat"],
                subs: [Subtitle(text: "hi", start: 1, dur: 2)],
                clips: [AudioClip(id: "c1", name: "1-Darl", start: 0, dur: 11.16,
                                  srcDur: 25.208, fadeIn: 0.4, fadeOut: 0.7)],
                events: [
                    .key(t: 0.5, code: .keyM, down: true),
                    .key(t: 0.7, code: .keyM, down: false),
                    .outfit(t: 3, slot: 12, name: "proff-hair"),
                    .outfit(t: 5, slot: 12, name: nil),
                    .motion(t: 6, speed: 180, rotationSpeed: 135, wobble: 4, size: 0.8),
                ],
                reactions: [ReactionInstance(id: "ri", reactionID: "shock",
                                             start: 7, dur: 2.5, intensity: 1.4)],
                name: "DARL",
                recStart: StartPose(x: 0.3, depth: 0, face: 1, spin: 42, zoom: 1.35),
                speed: 280, rotationSpeed: 72, locked: true, solo: true)],
            reactionLibrary: [ReactionDefinition(id: "shock", name: "Shock", dur: 2,
                                                 events: [
                                                    .key(t: 0, code: .slash, down: true),
                                                    .outfit(t: 0.3, slot: 12, name: "chef-hat"),
                                                    .key(t: 2, code: .slash, down: false),
                                                 ])],
            audioTracks: [AudioTrack(id: "t1", name: "SAGE")],
            imageTracks: [ImageTrack(id: "it", name: "Props", cues: [
                ImageCue(id: "ic", assetID: "a1", start: 0, dur: 3,
                         from: ImagePlacement(), to: ImagePlacement(x: 0.9, y: 0.1, scale: 0.5),
                         speed: 7.2, rotationSpeed: 3.4,
                         playback: MediaPlayback(trimStart: 0.4, trimEnd: 2.7, rate: 1.5,
                                                 reverse: true, loop: false, freezeAt: 1.2,
                                                 phaseOffset: 0.6),
                         appearance: MediaAppearance(
                            tint: MediaColor(red: 0.2, green: 0.4, blue: 0.8),
                            tintAmount: 0.35, brightness: 0.1, contrast: 1.2,
                            saturation: 0.7, outline: 8, shadow: 0.6, cleanup: 0.4),
                         mask: .roundedRectangle, maskRadius: 0.2,
                         pivot: MediaPivot(x: 0.25, y: 0.75)),
            ])],
            backgroundTracks: [BackgroundTrack(id: "bt", name: "BG", cues: [
                BackgroundCue(id: "bc", assetID: "a1", start: 0, dur: 10, crop: .fit),
            ])],
            lights: [Light(x: 0.8, y: 0.18)],
            cropAnchors: [3.0, 12.4],
            markers: [
                TimelineMarker(id: "m1", name: "Cold open", start: 0, color: .orange),
                TimelineMarker(id: "s1", name: "Act one", start: 3, kind: .section,
                               duration: 9.4, color: .blue),
            ]
        ),
        assets: [Asset(id: "a1", name: "thing", kind: .image, file: "a1.png")],
        show: [ShowSegment(name: "Scene 1 3.0–12.4s", from: 3, to: 12.4)],
        settings: Settings(activeScene: 0, lightSize: 120)
    )
    let data = try JSONEncoder().encode(doc)
    let back = try JSONDecoder().decode(ShowDocument.self, from: data)
    #expect(back == doc)
}

@Test func visualAndCharacterSpeedDefaultsDecode() throws {
    let cue = try JSONDecoder().decode(
        ImageCue.self,
        from: Data(#"{"id":"i","assetID":"a","start":0,"dur":2,"from":{"x":0.5,"y":0.5,"scale":0.2,"rotation":0}}"#.utf8))
    #expect(cue.speed == ImageCue.defaultSpeed)
    #expect(cue.rotationSpeed == ImageCue.defaultRotationSpeed)
    #expect(cue.playback == MediaPlayback())
    #expect(cue.appearance == MediaAppearance())
    #expect(cue.mask == .none)
    #expect(cue.maskRadius == 0.12)
    #expect(cue.pivot == .center)

    let character = try JSONDecoder().decode(
        Character.self,
        from: Data(#"{"body":"orange"}"#.utf8))
    #expect(character.speed == 320)
    #expect(character.rotationSpeed == 90)
    #expect(character.reactions.isEmpty)
    #expect(!character.locked)
    #expect(!character.solo)

    let oldClip = try JSONDecoder().decode(
        AudioClip.self,
        from: Data(#"{"id":"a","name":"old","start":0,"dur":2,"offset":0,"srcDur":2}"#.utf8))
    #expect(oldClip.fadeIn == 0)
    #expect(oldClip.fadeOut == 0)

    let reaction = try JSONDecoder().decode(
        ReactionInstance.self,
        from: Data(#"{"id":"i","reactionID":"r","start":1,"dur":2}"#.utf8))
    #expect(reaction.intensity == 1)

    let oldStart = try JSONDecoder().decode(
        StartPose.self,
        from: Data(#"{"x":0.25,"depth":-0.4,"face":-1}"#.utf8))
    #expect(oldStart == StartPose(x: 0.25, depth: -0.4, face: -1, spin: 0, zoom: 1))
}

@Test func audioFadeEnvelopeIsStableAndClamped() {
    let clip = AudioClip(id: "a", name: "take", start: 10, dur: 4, srcDur: 4,
                         fadeIn: 1, fadeOut: 2)
    #expect(clip.level(at: 9.9) == 0)
    #expect(clip.level(at: 10) == 0)
    #expect(abs(clip.level(at: 10.5) - 0.5) < 1e-9)
    #expect(clip.level(at: 11) == 1)
    #expect(abs(clip.level(at: 13) - 0.5) < 1e-9)
    #expect(clip.level(at: 14) == 0)
    #expect(clip.level(at: 14.1) == 0)

    let clamped = AudioClip(id: "b", name: "short", start: 0, dur: 1, srcDur: 1,
                            fadeIn: 5, fadeOut: -2)
    #expect(clamped.fadeIn == 1)
    #expect(clamped.fadeOut == 0)
}

@Test func editableShowJSONRoundTripsAndRejectsUnknownFields() throws {
    let character = Character(body: .pink, x: 0.25, name: "Pinky")
    let text = try ShowJSONCodec.encode(character: character)
    #expect(try ShowJSONCodec.decodeCharacter(text) == character)
    #expect(text.contains("\n"))

    let document = ShowDocument(stage: SceneState(
        characters: [character],
        backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))
    let documentText = try ShowJSONCodec.encode(document: document)
    #expect(try ShowJSONCodec.decodeDocument(documentText) == document)

    #expect(throws: ShowJSONCodec.UnsupportedDocumentVersionError(version: 2)) {
        try ShowJSONCodec.decodeDocument(#"{"version":2,"scenes":[]}"#)
    }

    do {
        _ = try ShowJSONCodec.decodeCharacter(#"{"body":42}"#)
        Issue.record("Expected a typed decoding error")
    } catch {
        #expect(ShowJSONCodec.readableMessage(for: error).contains("$.body"))
    }

    let typo = #"{"body":"pink","x":0.25,"speeed":400}"#
    do {
        _ = try ShowJSONCodec.decodeCharacter(typo)
        Issue.record("Expected the unsupported field to be rejected")
    } catch let error as ShowJSONCodec.UnsupportedFieldsError {
        #expect(error.paths == ["$.speeed"])
    }

    let nestedTypo = #"{"body":"pink","recStart":{"x":0.5,"depth":0,"face":1,"spinn":30}}"#
    do {
        _ = try ShowJSONCodec.decodeCharacter(nestedTypo)
        Issue.record("Expected the nested unsupported field to be rejected")
    } catch let error as ShowJSONCodec.UnsupportedFieldsError {
        #expect(error.paths == ["$.recStart.spinn"])
    }
}

@Test func rotatedVisualHitTestHonorsAspectAndPivot() {
    var cue = ImageCue(id: "visual", assetID: "asset", start: 0, dur: 2,
                       from: ImagePlacement(x: 0.5, y: 0.5, scale: 0.4,
                                            rotation: 90))
    cue.pivot = MediaPivot(x: 0, y: 0.5)

    // A 2:1 asset rotated 90° extends vertically from its left-edge pivot.
    #expect(cue.containsStagePoint(x: 0.5, y: 0.75, at: 0,
                                   assetAspect: 2, stageAspect: 16.0 / 9.0))
    #expect(!cue.containsStagePoint(x: 0.8, y: 0.5, at: 0,
                                    assetAspect: 2, stageAspect: 16.0 / 9.0))
}

@Test func mediaPlaybackMapsShowTimeIntoTrimmedSource() {
    var cue = ImageCue(id: "v", assetID: "video", start: 5, dur: 20,
                       from: ImagePlacement(),
                       playback: MediaPlayback(trimStart: 2, trimEnd: 6, rate: 2,
                                               reverse: false, loop: false))
    #expect(cue.sourceTime(at: 5, sourceDuration: 10) == 2)
    #expect(abs(cue.sourceTime(at: 6, sourceDuration: 10) - 4) < 1e-9)
    #expect(cue.sourceTime(at: 99, sourceDuration: 10) < 6)
    #expect(cue.sourceTime(at: 99, sourceDuration: 10) > 5.99)

    cue.playback.reverse = true
    #expect(cue.sourceTime(at: 5, sourceDuration: 10) < 6)
    #expect(cue.sourceTime(at: 5, sourceDuration: 10) > 5.99)
    #expect(abs(cue.sourceTime(at: 6, sourceDuration: 10) - 3.999) < 0.002)

    cue.playback.loop = true
    cue.playback.reverse = false
    #expect(cue.sourceTime(at: 7, sourceDuration: 10) == 2) // 4 source seconds wraps
    cue.playback.freezeAt = 3.25
    #expect(cue.sourceTime(at: 5, sourceDuration: 10) == 3.25)
    #expect(cue.sourceTime(at: 50, sourceDuration: 10) == 3.25)
}

@Test func continuedMediaPlaybackPreservesSourcePhaseAcrossSplits() {
    let original = ImageCue(
        id: "head", assetID: "video", start: 5, dur: 8,
        from: ImagePlacement(),
        playback: MediaPlayback(trimStart: 1, trimEnd: 5, rate: 1.5,
                                reverse: true, loop: true, phaseOffset: 0.4))
    let splitTime = 7.25
    var tail = original
    tail.id = "tail"
    tail.playback = original.continuedPlayback(at: splitTime)
    tail.start = splitTime
    tail.dur = original.start + original.dur - splitTime

    for t in [splitTime, splitTime + 0.2, splitTime + 2.75] {
        #expect(abs(original.sourceTime(at: t, sourceDuration: 7)
                    - tail.sourceTime(at: t, sourceDuration: 7)) < 1e-9)
    }
}

@Test func cameraAndFrameDefaults() throws {
    // Pre-camera documents: settings without frame keys → 16:9; cues without
    // camera keys → nil (identity camera).
    let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"activeScene":0,"lightSize":0}"#.utf8))
    #expect(old.frameW == 16 && old.frameH == 9)
    #expect(abs(old.frameAspect - 16.0 / 9.0) < 1e-9)
    let cue = try JSONDecoder().decode(
        BackgroundCue.self,
        from: Data(#"{"id":"b","assetID":"a","start":0,"dur":10,"crop":"cover"}"#.utf8))
    #expect(cue.camera(at: 5) == nil)

    // Camera interpolation: midpoint of an animated cue is halfway.
    var animated = cue
    animated.camFrom = CameraState(x: 0.2, y: 0.4, zoom: 1)
    animated.camTo = CameraState(x: 0.8, y: 0.6, zoom: 3)
    let mid = animated.camera(at: 5)
    #expect(mid == CameraState(x: 0.5, y: 0.5, zoom: 2))
    // Static camera holds its from state; round trip keeps the fields.
    animated.camTo = nil
    #expect(animated.camera(at: 9) == animated.camFrom)
    let back = try JSONDecoder().decode(BackgroundCue.self, from: JSONEncoder().encode(animated))
    #expect(back == animated)
}

@Test func perfEventWireFormat() throws {
    let key = PerfEvent.key(t: 1.25, code: .arrowRight, down: true)
    let keyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(key)) as! [String: Any]
    #expect(keyJSON["code"] as? String == "ArrowRight")
    #expect(keyJSON["down"] as? Bool == true)
    #expect(keyJSON["t"] as? Double == 1.25)

    let outfit = PerfEvent.outfit(t: 2, slot: 12, name: nil)
    let outfitJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(outfit)) as! [String: Any]
    let change = outfitJSON["outfit"] as! [String: Any]
    #expect(change["slot"] as? Int == 12)
    #expect(change["name"] == nil)

    let motion = PerfEvent.motion(t: 3, speed: 240, rotationSpeed: 135, wobble: nil, size: nil)
    let motionJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(motion)) as! [String: Any]
    let params = motionJSON["motion"] as! [String: Any]
    #expect(params["speed"] as? Double == 240)
    #expect(params["rotationSpeed"] as? Double == 135)
    #expect(try JSONDecoder().decode(PerfEvent.self, from: JSONEncoder().encode(motion)) == motion)
}

@Test func panWireFormat() throws {
    #expect(try JSONDecoder().decode([Pan].self, from: Data(#"["follow","narrow","wide",-0.5]"#.utf8))
        == [.follow, .narrow, .wide, .value(-0.5)])
}

@Test func eventGroupsMatchWeb() {
    let expected: [EventCode: EventGroup] = [
        .arrowLeft: .move, .arrowRight: .move,
        .arrowUp: .depth, .arrowDown: .depth,
        .keyT: .tilt, .keyB: .tilt,
        .keyM: .talk,
        .comma: .blink, .slash: .blink, .period: .blink,
        .keyJ: .jump,
    ]
    for (code, group) in expected { #expect(code.group == group, "\(code)") }
    #expect(EventCode.comma.blinkExpression == .closed)
    #expect(EventCode.slash.blinkExpression == .brow1)
    #expect(EventCode.period.blinkExpression == .brow2)
    #expect(EventCode.keyM.blinkExpression == nil)
}
