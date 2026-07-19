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
    /// Per-slot dissolve state during the 0.8s after an outfit change: the
    /// item being removed (`prev`) fades out in pixel chunks while the new one
    /// (in `outfit`) fades in. Empty once transitions settle.
    public var outfitAnim: [Int: OutfitAnim]
    public var activeSubtitle: String?
    /// True while any movement key is held (drives gait bob/sway rendering).
    public var moving: Bool
    /// Free rotation (degrees) from shift+←/→, on top of gait/tilt rotation.
    public var spin: Double
    /// Scale multiplier from +/− (1 = neutral).
    public var zoom: Double
    /// Motion params resolved at t (base value, overridden by timed changes).
    public var wobble: Double
    public var size: Double

    public struct JumpState: Equatable, Sendable {
        public var progress: Double
        public var height: Double

        public init(progress: Double, height: Double) {
            self.progress = progress
            self.height = height
        }
    }

    /// One slot's outfit dissolve: `prev` is the outgoing item (nil when the
    /// slot was empty), `progress` runs 0→1 over the transition.
    public struct OutfitAnim: Equatable, Sendable {
        public var prev: String?
        public var progress: Double
        public init(prev: String?, progress: Double) { self.prev = prev; self.progress = progress }
    }

    /// Seconds an outfit add/remove takes to dissolve in/out — banny-minter's
    /// EQUIP_DURATION_MILLIS (400ms), i.e. 4 fuzz steps × 100ms.
    public static let outfitDissolve = 0.4

    public init(x: Double, depth: Double, phase: Double, tilt: Double, face: Int,
                eye: EyeExpression, talking: Bool, jump: JumpState?, outfit: [Int: String],
                activeSubtitle: String?, moving: Bool, spin: Double = 0, zoom: Double = 1,
                wobble: Double = 7, size: Double = 1, outfitAnim: [Int: OutfitAnim] = [:]) {
        self.x = x
        self.depth = depth
        self.phase = phase
        self.tilt = tilt
        self.face = face
        self.eye = eye
        self.talking = talking
        self.jump = jump
        self.outfit = outfit
        self.outfitAnim = outfitAnim
        self.activeSubtitle = activeSubtitle
        self.moving = moving
        self.spin = spin
        self.zoom = zoom
        self.wobble = wobble
        self.size = size
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
        // Checkpointed + cached: bit-identical to simulatePosition, but a
        // query costs ~10s of integration, not t — hour-long shows stay 60fps.
        let sim = PositionTimelineCache.shared.timeline(
            events: c.events,
            recStart: c.recStart ?? StartPose(x: c.x, depth: c.depth, face: c.face),
            speed: c.speed, gScale: state.gScale, coveringAtLeast: t)
            .pose(at: t)

        // State scan (web resetToTime): last-writer-wins over events strictly before t.
        var eye = EyeExpression.open
        var tilt = 0.0
        var talking = false
        var outfit = c.baseOutfit
        var wobble = c.wobble
        var size = c.size
        var lastOutfitChange: [Int: (t: Double, prev: String?)] = [:]
        var lastJumpDown: Double?
        var heldLeft = false, heldRight = false, heldUp = false, heldDown = false

        for ev in c.events {
            guard ev.t < t else { break }
            switch ev {
            case .motion(_, _, let w, let z):
                if let w { wobble = w }
                if let z { size = z }
            case .outfit(let et, let slot, let name):
                lastOutfitChange[slot] = (et, outfit[slot])
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

        // Pixel-chunk dissolve for any slot changed within the last 0.8s.
        var outfitAnim: [Int: CharacterPose.OutfitAnim] = [:]
        for (slot, change) in lastOutfitChange {
            let p = (t - change.t) / CharacterPose.outfitDissolve
            if p >= 0, p < 1 { outfitAnim[slot] = .init(prev: change.prev, progress: p) }
        }

        return CharacterPose(x: sim.x, depth: sim.depth, phase: sim.phase, tilt: tilt,
                             face: sim.face, eye: eye, talking: talking, jump: jump,
                             outfit: outfit, activeSubtitle: sub?.text,
                             moving: heldLeft || heldRight || heldUp || heldDown,
                             spin: sim.spin, zoom: sim.zoom, wobble: wobble, size: size,
                             outfitAnim: outfitAnim)
    }
}
