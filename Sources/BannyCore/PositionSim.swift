import Foundation

/// Position/orientation of a character derived purely from its recorded events at time t.
public struct SimPose: Equatable, Sendable {
    /// Foot X, fraction of stage width (clamped to the edge margin 0.044..0.956).
    public var x: Double
    public var depth: Double
    /// Accumulated gait phase (radians); advances at speed/22 while moving.
    public var phase: Double
    public var face: Int
}

/// Deterministic walk/turn/depth simulation — a direct port of the webapp's
/// `simulatePos`: fixed 1/60 s steps with an exact partial final step, run in
/// normalized stage space (the web's `speed*(W/900)*dt` px integration is
/// `speed/900*dt` in fraction-of-width space, W-invariant).
///
/// Position is a pure function of (events, t): live playback, scrubbing, and
/// export all agree to the pixel.
public func simulatePosition(events: [PerfEvent], recStart: StartPose?, speed: Double,
                             gScale: Double, at t: Double) -> SimPose {
    let start = recStart ?? StartPose(x: 0.5, depth: 0, face: 1)
    var x = start.x
    var depth = start.depth
    var face = start.face
    var phase = 0.0
    var turnUntil = 0.0
    var ei = 0
    var heldLeft = false, heldRight = false, heldUp = false, heldDown = false

    let dt = 1.0 / 60.0
    let depthRate = (speed / 320) * 0.36 / max(gScale, 0.1)
    let edge = 0.044

    var tt = 0.0
    while tt < t - 1e-9 {
        while ei < events.count, events[ei].t <= tt {
            let ev = events[ei]
            ei += 1
            guard case .key(_, let code, let down) = ev else { continue }
            switch code {
            case .arrowRight, .arrowLeft:
                let dir = code == .arrowRight ? 1 : -1
                let alreadyHeld = code == .arrowRight ? heldRight : heldLeft
                if down {
                    if !alreadyHeld && face != dir {
                        face = dir
                        turnUntil = tt + 0.1
                    }
                    if code == .arrowRight { heldRight = true } else { heldLeft = true }
                } else {
                    if code == .arrowRight { heldRight = false } else { heldLeft = false }
                }
            case .arrowUp: heldUp = down
            case .arrowDown: heldDown = down
            default: break
            }
        }
        let h = min(dt, t - tt)
        var dx = 0.0
        let dz = (heldUp ? 1.0 : 0) - (heldDown ? 1.0 : 0)
        if heldRight && face == 1 && tt >= turnUntil { dx = 1 }
        else if heldLeft && face == -1 && tt >= turnUntil { dx = -1 }
        x = min(1 - edge, max(edge, x + speed / 900 * dx * h))
        depth = min(1, max(-12, depth + dz * h * depthRate))
        if dx != 0 || dz != 0 { phase += h * speed / 22 }
        tt += h
    }
    return SimPose(x: x, depth: depth, phase: phase, face: face)
}
