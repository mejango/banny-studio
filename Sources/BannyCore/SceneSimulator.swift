import Foundation

/// Full derived state of one character at a moment in time.
public struct CharacterPose: Equatable, Sendable {
    public var x: Double
    public var depth: Double
    public var phase: Double
    /// Degrees: +9 forward, -9 back, 0 neutral.
    public var tilt: Double
    public var face: Int
    public var eye: EyeExpression
    public var talking: Bool
    /// Mid-jump: progress 0..1 and height (30/gravity). Nil when grounded.
    public var jump: JumpState?
    /// Resolved outfit at t: baseOutfit overlaid with timed changes.
    public var outfit: [Int: String]
    public var activeSubtitle: String?
    /// True while any movement key is held (drives gait bob/sway rendering).
    public var moving: Bool

    public struct JumpState: Equatable, Sendable {
        public var progress: Double
        public var height: Double
    }
}

/// Derives every character's full state as a pure function of (scene, t).
/// Live playback, scrubbing, and export all call this — no drift, ever.
public struct SceneSimulator: Sendable {
    public let state: SceneState

    public init(state: SceneState) {
        self.state = state
    }

    public func pose(characterIndex: Int, at t: Double) -> CharacterPose {
        let c = state.characters[characterIndex]
        let sim = simulatePosition(events: c.events,
                                   recStart: c.recStart ?? StartPose(x: c.x, depth: c.depth, face: c.face),
                                   speed: c.speed, gScale: state.gScale, at: t)

        // State scan (web resetToTime): last-writer-wins over events strictly before t.
        var eye = EyeExpression.open
        var tilt = 0.0
        var talking = false
        var outfit = c.baseOutfit
        var lastJumpDown: Double?
        var heldLeft = false, heldRight = false, heldUp = false, heldDown = false

        for ev in c.events {
            guard ev.t < t else { break }
            switch ev {
            case .outfit(_, let slot, let name):
                if let name { outfit[slot] = name } else { outfit.removeValue(forKey: slot) }
            case .key(let te, let code, let down):
                if let blink = code.blinkExpression {
                    eye = down ? blink : .open
                } else {
                    switch code {
                    case .keyM: talking = down
                    case .keyT: tilt = down ? 9 : 0
                    case .keyB: tilt = down ? -9 : 0
                    case .keyJ: if down { lastJumpDown = te }
                    case .arrowLeft: heldLeft = down
                    case .arrowRight: heldRight = down
                    case .arrowUp: heldUp = down
                    case .arrowDown: heldDown = down
                    default: break
                    }
                }
            }
        }

        var jump: CharacterPose.JumpState?
        if let tj = lastJumpDown {
            // Web: dur = round(460/gravity) ms, height 30/gravity.
            let dur = (460.0 / state.gravity).rounded() / 1000.0
            let progress = (t - tj) / dur
            if progress >= 0, progress < 1 {
                jump = .init(progress: progress, height: 30 / state.gravity)
            }
        }

        // Active caption: latest-starting subtitle covering t wins.
        var sub: Subtitle?
        for s in c.subs where t >= s.start && t < s.start + s.dur {
            if sub == nil || s.start > sub!.start { sub = s }
        }

        return CharacterPose(x: sim.x, depth: sim.depth, phase: sim.phase, tilt: tilt,
                             face: sim.face, eye: eye, talking: talking, jump: jump,
                             outfit: outfit, activeSubtitle: sub?.text,
                             moving: heldLeft || heldRight || heldUp || heldDown)
    }
}
