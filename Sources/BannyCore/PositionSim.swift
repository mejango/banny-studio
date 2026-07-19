import Foundation

/// Position/orientation of a character derived purely from its recorded events at time t.
public struct SimPose: Equatable, Sendable {
    /// Foot X, fraction of stage width (clamped to the edge margin 0.044..0.956).
    public var x: Double
    public var depth: Double
    /// Accumulated gait phase (radians); advances at speed/22 while moving.
    public var phase: Double
    public var face: Int
    /// Free rotation in degrees, accumulated while shift+←/→ held.
    public var spin: Double = 0
    /// Extra scale multiplier, accumulated while +/− held (1 = neutral).
    public var zoom: Double = 1
}

/// The integration loop's full state. A value captured at a FULL-step boundary
/// resumes with the exact float operations of a from-zero run — that's what
/// makes checkpointing bit-identical to the pure function.
struct SimState: Equatable {
    var x: Double
    var depth: Double
    var phase: Double
    var face: Int
    var turnUntil: Double
    var ei: Int
    var heldLeft = false, heldRight = false, heldUp = false, heldDown = false
    var spin = 0.0
    var zoom = 1.0
    var heldSpinL = false, heldSpinR = false, heldZoomIn = false, heldZoomOut = false
    /// Working walk speed — starts at the character's base, updated by
    /// `.motion` events over time. Drives position, gait phase, and rotation.
    var speed = 320.0
    var tt: Double
}

/// The webapp's `simulatePos` stepping: fixed 1/60 s steps with an exact
/// partial final step. ONE implementation — the one-shot query, the timeline
/// builder, and checkpoint resume all run this same code.
@inline(__always)
func integrate(_ s: inout SimState, events: [PerfEvent], gScale: Double, to t: Double,
               onFullStep: ((SimState) -> Void)? = nil) {
    let dt = 1.0 / 60.0
    let edge = 0.044
    while s.tt < t - 1e-9 {
        while s.ei < events.count, events[s.ei].t <= s.tt {
            let ev = events[s.ei]
            s.ei += 1
            // Timed speed changes take effect from here on.
            if case .motion(_, let sp, _, _) = ev { if let sp { s.speed = sp }; continue }
            guard case .key(_, let code, let down) = ev else { continue }
            switch code {
            case .arrowRight, .arrowLeft:
                let dir = code == .arrowRight ? 1 : -1
                let alreadyHeld = code == .arrowRight ? s.heldRight : s.heldLeft
                if down {
                    if !alreadyHeld && s.face != dir {
                        s.face = dir
                        s.turnUntil = s.tt + 0.1
                    }
                    if code == .arrowRight { s.heldRight = true } else { s.heldLeft = true }
                } else {
                    if code == .arrowRight { s.heldRight = false } else { s.heldLeft = false }
                }
            case .arrowUp: s.heldUp = down
            case .arrowDown: s.heldDown = down
            case .rotateLeft: s.heldSpinL = down
            case .rotateRight: s.heldSpinR = down
            case .zoomIn: s.heldZoomIn = down
            case .zoomOut: s.heldZoomOut = down
            case .spinReset: if down { s.spin = 0 }
            case .zoomReset: if down { s.zoom = 1 }
            default: break
            }
        }
        let h = min(dt, t - s.tt)
        let depthRate = simDepthRate(speed: s.speed, gScale: gScale)
        var dx = 0.0
        let dz = (s.heldUp ? 1.0 : 0) - (s.heldDown ? 1.0 : 0)
        if s.heldRight && s.face == 1 && s.tt >= s.turnUntil { dx = 1 }
        else if s.heldLeft && s.face == -1 && s.tt >= s.turnUntil { dx = -1 }
        s.x = min(1 - edge, max(edge, s.x + s.speed / 900 * dx * h))
        s.depth = min(1, max(-12, s.depth + dz * h * depthRate))
        if dx != 0 || dz != 0 { s.phase += h * s.speed / 22 }
        // Rotate at a rate that tracks the speed dial (90°/s at base 320);
        // zoom multiplicatively (~1.6×/s), clamped 0.2–5×.
        let dspin = (s.heldSpinR ? 1.0 : 0) - (s.heldSpinL ? 1.0 : 0)
        s.spin += dspin * (s.speed / 320 * 90) * h
        let dzoom = (s.heldZoomIn ? 1.0 : 0) - (s.heldZoomOut ? 1.0 : 0)
        if dzoom != 0 { s.zoom = min(5, max(0.2, s.zoom * (1 + dzoom * 1.6 * h))) }
        s.tt += h
        if h == dt { onFullStep?(s) }
    }
}

func initialSimState(recStart: StartPose?, speed: Double) -> SimState {
    let start = recStart ?? StartPose(x: 0.5, depth: 0, face: 1)
    var s = SimState(x: start.x, depth: start.depth, phase: 0, face: start.face,
                     turnUntil: 0, ei: 0, tt: 0)
    s.speed = speed
    return s
}

func simDepthRate(speed: Double, gScale: Double) -> Double {
    (speed / 320) * 0.36 / max(gScale, 0.1)
}

/// Deterministic walk/turn/depth simulation — a direct port of the webapp's
/// `simulatePos`: fixed 1/60 s steps with an exact partial final step, run in
/// normalized stage space (the web's `speed*(W/900)*dt` px integration is
/// `speed/900*dt` in fraction-of-width space, W-invariant).
///
/// Position is a pure function of (events, t): live playback, scrubbing, and
/// export all agree to the pixel. O(t) — interactive callers should go through
/// `PositionTimelineCache` (SceneSimulator does), which answers in O(10s).
public func simulatePosition(events: [PerfEvent], recStart: StartPose?, speed: Double,
                             gScale: Double, at t: Double) -> SimPose {
    var s = initialSimState(recStart: recStart, speed: speed)
    integrate(&s, events: events, gScale: gScale, to: t)
    return SimPose(x: s.x, depth: s.depth, phase: s.phase, face: s.face,
                   spin: s.spin, zoom: s.zoom)
}

/// Checkpointed position timeline for one character's event stream: pose
/// queries integrate at most ~10 s from the nearest checkpoint instead of the
/// full show — hour-long shows answer as fast as short ones. Bit-identical to
/// `simulatePosition` (checkpoints sit on full-step boundaries only).
public final class PositionTimeline: @unchecked Sendable { // immutable after init
    private let events: [PerfEvent]
    private let gScale: Double
    private let checkpoints: [SimState] // [0] is the t=0 state; ~10s apart
    let horizon: Double

    /// Steps between checkpoints: 600 full steps = 10 s of show time.
    private static let strideSteps = 600

    init(events: [PerfEvent], recStart: StartPose?, speed: Double, gScale: Double,
         upTo horizon: Double) {
        self.events = events
        self.gScale = gScale
        self.horizon = horizon
        var s = initialSimState(recStart: recStart, speed: speed)
        var cps = [s]
        var step = 0
        integrate(&s, events: events, gScale: gScale, to: horizon) { st in
            step += 1
            if step % Self.strideSteps == 0 { cps.append(st) }
        }
        self.checkpoints = cps
    }

    public func pose(at t: Double) -> SimPose {
        // Last checkpoint at or before t (they're sorted by tt).
        var lo = 0
        var hi = checkpoints.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if checkpoints[mid].tt <= t { lo = mid } else { hi = mid - 1 }
        }
        var s = checkpoints[lo]
        integrate(&s, events: events, gScale: gScale, to: t)
        return SimPose(x: s.x, depth: s.depth, phase: s.phase, face: s.face,
                       spin: s.spin, zoom: s.zoom)
    }
}

/// Process-wide timeline cache keyed by the exact simulation inputs. Small LRU:
/// one entry per live character stream (editor + export can share safely —
/// timelines are immutable and lookups are locked).
public final class PositionTimelineCache: @unchecked Sendable {
    public static let shared = PositionTimelineCache()

    private struct Key: Equatable {
        var events: [PerfEvent]
        var recStart: StartPose?
        var speed: Double
        var gScale: Double
    }

    private let lock = NSLock()
    private var entries: [(key: Key, timeline: PositionTimeline)] = []
    private static let capacity = 24

    public func timeline(events: [PerfEvent], recStart: StartPose?, speed: Double,
                         gScale: Double, coveringAtLeast t: Double) -> PositionTimeline {
        let key = Key(events: events, recStart: recStart, speed: speed, gScale: gScale)
        lock.lock()
        defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.key == key && $0.timeline.horizon >= t }) {
            let hit = entries.remove(at: i)
            entries.insert(hit, at: 0) // LRU front
            return hit.timeline
        }
        entries.removeAll { $0.key == key } // stale horizon
        // Build past t so steady playback rebuilds at most every ~2 minutes.
        let timeline = PositionTimeline(events: events, recStart: recStart, speed: speed,
                                        gScale: gScale, upTo: t + 120)
        entries.insert((key, timeline), at: 0)
        if entries.count > Self.capacity { entries.removeLast() }
        return timeline
    }
}
