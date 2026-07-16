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
                clips: [AudioClip(id: "c1", name: "1-Darl", start: 0, dur: 11.16, srcDur: 25.208)],
                events: [
                    .key(t: 0.5, code: .keyM, down: true),
                    .key(t: 0.7, code: .keyM, down: false),
                    .outfit(t: 3, slot: 12, name: "proff-hair"),
                    .outfit(t: 5, slot: 12, name: nil),
                ],
                name: "DARL",
                recStart: StartPose(x: 0.3, depth: 0, face: 1))],
            audioTracks: [AudioTrack(id: "t1", name: "SAGE")],
            imageTracks: [ImageTrack(id: "it", name: "Props", cues: [
                ImageCue(id: "ic", assetID: "a1", start: 0, dur: 3,
                         from: ImagePlacement(), to: ImagePlacement(x: 0.9, y: 0.1, scale: 0.5)),
            ])],
            backgroundTracks: [BackgroundTrack(id: "bt", name: "BG", cues: [
                BackgroundCue(id: "bc", assetID: "a1", start: 0, dur: 10, crop: .fit),
            ])],
            lights: [Light(x: 0.8, y: 0.18)],
            cropAnchors: [3.0, 12.4]
        ),
        assets: [Asset(id: "a1", name: "thing", kind: .image, file: "a1.png")],
        show: [ShowSegment(name: "Scene 1 3.0–12.4s", from: 3, to: 12.4)],
        settings: Settings(activeScene: 0, lightSize: 120)
    )
    let data = try JSONEncoder().encode(doc)
    let back = try JSONDecoder().decode(ShowDocument.self, from: data)
    #expect(back == doc)
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
