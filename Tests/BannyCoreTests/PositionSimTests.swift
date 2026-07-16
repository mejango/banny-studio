import Foundation
import Testing
@testable import BannyCore

/// Golden fixture: states sampled by running the ORIGINAL webapp JS math on ep1
/// (tools/gen-golden.mjs). The Swift sim must reproduce them.
struct GoldenFixture: Decodable {
    var sampleTimes: [Double]
    var scenes: [GScene]
    struct GScene: Decodable {
        var id: String
        var name: String
        var gScale: Double
        var characters: [GCharacter]
    }
    struct GCharacter: Decodable {
        var index: Int
        var name: String
        var eventCount: Int
        var samples: [GSample]
    }
    struct GSample: Decodable {
        var t, x, depth, phase: Double
        var face: Int
        var eye: String
        var tilt: Double
        var talking: Bool
        var held: [String]
    }
}

func loadGolden() throws -> GoldenFixture {
    let url = Bundle.module.url(forResource: "Fixtures/golden-ep1", withExtension: "json")!
    return try JSONDecoder().decode(GoldenFixture.self, from: Data(contentsOf: url))
}

/// Events for the golden characters come from the real staging doc, imported via V1Importer
/// once it exists. Until Task 7 lands, this loader reads the raw v1 JSON directly.
func loadEp1V1() throws -> [String: [(name: String, events: [PerfEvent], recStart: StartPose?)]] {
    let url = URL(fileURLWithPath: "/Users/jango/Documents/banny/show/ep1/beat1/staging/1.json")
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let studio = raw["studio"] as! [String: Any]
    var out: [String: [(String, [PerfEvent], StartPose?)]] = [:]
    for scene in studio["scenes"] as! [[String: Any]] {
        guard let state = scene["state"] as? [String: Any] else { continue }
        var chars: [(String, [PerfEvent], StartPose?)] = []
        for (i, b) in (state["bannys"] as! [[String: Any]]).enumerated() {
            let norm = { (v: Double) in v > 1.5 ? v / 900 : v }
            var events: [PerfEvent] = []
            for e in b["events"] as? [[String: Any]] ?? [] {
                let t = (e["t"] as! NSNumber).doubleValue
                let code = e["code"] as! String
                if code == "outfit" {
                    events.append(.outfit(t: t, slot: (e["cat"] as! NSNumber).intValue, name: e["name"] as? String))
                } else if let ec = EventCode(rawValue: code) {
                    events.append(.key(t: t, code: ec, down: e["type"] as? String == "d"))
                }
            }
            events.sort { $0.t < $1.t }
            var recStart: StartPose?
            if let rs = b["recStart"] as? [String: Any] {
                recStart = StartPose(x: norm((rs["x"] as! NSNumber).doubleValue),
                                     depth: (rs["depth"] as? NSNumber)?.doubleValue ?? 0,
                                     face: (rs["face"] as? NSNumber)?.intValue ?? 1)
            }
            chars.append((b["name"] as? String ?? String(i + 1), events, recStart))
        }
        out[scene["id"] as! String] = chars
    }
    return out
}

let ep1Exists = FileManager.default.fileExists(atPath: "/Users/jango/Documents/banny/show/ep1/beat1/staging/1.json")

@Test(.enabled(if: ep1Exists)) func positionSimMatchesOriginalJS() throws {
    let golden = try loadGolden()
    let ep1 = try loadEp1V1()
    var checked = 0
    for scene in golden.scenes {
        let chars = try #require(ep1[scene.id])
        for gc in scene.characters {
            let (name, events, recStart) = chars[gc.index]
            #expect(name == gc.name)
            #expect(events.count == gc.eventCount)
            for s in gc.samples {
                let pose = simulatePosition(events: events, recStart: recStart, speed: 320,
                                            gScale: scene.gScale, at: s.t)
                #expect(abs(pose.x - s.x) < 1e-9, "\(gc.name) x at t=\(s.t)")
                #expect(abs(pose.depth - s.depth) < 1e-9, "\(gc.name) depth at t=\(s.t)")
                #expect(pose.face == s.face, "\(gc.name) face at t=\(s.t)")
                #expect(abs(pose.phase - s.phase) < 1e-6, "\(gc.name) phase at t=\(s.t)")
                checked += 1
            }
        }
    }
    #expect(checked >= 40)
}

@Test func xStaysInsideEdgeMargins() {
    // Walk hard right for 60s from the right edge: x must clamp at 1-0.044.
    let events: [PerfEvent] = [.key(t: 0, code: .arrowRight, down: true)]
    let pose = simulatePosition(events: events, recStart: StartPose(x: 0.9, depth: 0, face: 1),
                                speed: 600, gScale: 0.6, at: 60)
    #expect(pose.x == 1 - 0.044)
    let left = simulatePosition(events: [.key(t: 0, code: .arrowLeft, down: true)],
                                recStart: StartPose(x: 0.1, depth: 0, face: -1),
                                speed: 600, gScale: 0.6, at: 60)
    #expect(left.x == 0.044)
}

@Test func turnDelayBlocksMovement() {
    // Facing left, press right: face flips instantly but movement waits 0.1s.
    let events: [PerfEvent] = [.key(t: 0, code: .arrowRight, down: true)]
    let mid = simulatePosition(events: events, recStart: StartPose(x: 0.5, depth: 0, face: -1),
                               speed: 320, gScale: 0.6, at: 0.05)
    #expect(mid.face == 1)
    #expect(mid.x == 0.5)
    let after = simulatePosition(events: events, recStart: StartPose(x: 0.5, depth: 0, face: -1),
                                 speed: 320, gScale: 0.6, at: 0.2)
    #expect(after.x > 0.5)
}

/// The checkpointed timeline must be BIT-identical to the from-zero pure
/// function — same float ops in the same order — across a fuzz of event
/// streams and query times. This is the license for SceneSimulator to use it.
@Test func timelineMatchesFromZeroExactly() {
    var seed: UInt64 = 0x5EED
    func rand() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(UInt64.max >> 11)
    }
    let codes: [EventCode] = [.arrowLeft, .arrowRight, .arrowUp, .arrowDown, .keyJ]
    for round in 0..<5 {
        var events: [PerfEvent] = []
        var t = 0.0
        for _ in 0..<300 {
            t += rand() * 1.2
            events.append(.key(t: (t * 1000).rounded() / 1000,
                               code: codes[Int(rand() * 4.99)], down: rand() < 0.5))
        }
        let recStart = StartPose(x: 0.2 + rand() * 0.6, depth: rand() - 0.5, face: rand() < 0.5 ? 1 : -1)
        let speed = 40 + rand() * 560
        let gScale = 0.3 + rand() * 0.9
        let timeline = PositionTimeline(events: events, recStart: recStart,
                                        speed: speed, gScale: gScale, upTo: t + 60)
        for _ in 0..<120 {
            let q = rand() * (t + 50)
            let a = timeline.pose(at: q)
            let b = simulatePosition(events: events, recStart: recStart,
                                     speed: speed, gScale: gScale, at: q)
            #expect(a == b, "round \(round) t=\(q)")
        }
    }
}

/// Hour-long shows must answer pose queries at tick rate: warm-timeline
/// queries near t=3600 stay ~10s-of-integration cheap.
@Test func hourLongPoseQueriesStayFast() {
    var events: [PerfEvent] = []
    for i in 0..<2000 {
        let t = Double(i) * 1.8
        events.append(.key(t: t, code: i % 2 == 0 ? .arrowRight : .arrowLeft, down: i % 4 < 2))
    }
    let c = Character(body: .orange, events: events, recStart: StartPose(x: 0.5, depth: 0, face: 1))
    let sim = SceneSimulator(state: SceneState(characters: [c], gScale: 0.6))
    _ = sim.pose(characterIndex: 0, at: 3599) // warm the cached timeline
    let t0 = ContinuousClock.now
    for i in 0..<60 { // one second of playback ticks at the hour mark
        _ = sim.pose(characterIndex: 0, at: 3540 + Double(i) / 60.0)
    }
    let elapsed = ContinuousClock.now - t0
    #expect(elapsed < .milliseconds(100), "60 hour-mark queries took \(elapsed)")
}
