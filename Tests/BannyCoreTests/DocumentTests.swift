import Foundation
import Testing
@testable import BannyCore

@Test func documentRoundTrip() throws {
    let doc = ShowDocument(
        scenes: [Scene(id: "s1", name: "Scene 1", state: SceneState(
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
            lights: [Light(x: 0.8, y: 0.18)],
            cropAnchors: [3.0, 12.4],
            background: .image(file: "s1.png", crop: .cover)
        ))],
        show: [ShowSegment(sceneID: "s1", name: "Scene 1 3.0–12.4s", from: 3, to: 12.4)],
        settings: Settings(activeScene: 0, lightSize: 120)
    )
    let data = try JSONEncoder().encode(doc)
    let back = try JSONDecoder().decode(ShowDocument.self, from: data)
    #expect(back == doc)
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
