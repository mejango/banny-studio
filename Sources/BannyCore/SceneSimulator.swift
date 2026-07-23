import Foundation

/// Full derived state of one character at a moment in time.
public struct CharacterPose: Equatable, Sendable {
    public var x: Double
    public var depth: Double
    public var phase: Double
    /// Degrees: +9 forward, -9 back, 0 neutral (instant, matches the web math).
    public var tilt: Double
    /// Eased tilt for rendering — leans in/out over ~0.15s instead of snapping.
    public var leanTilt: Double
    public var face: Int
    public var eye: EyeExpression
    public var mouthShape: MouthShape
    /// Compatibility shorthand used by manual M-key performances.
    public var talking: Bool {
        get { mouthShape != .closed }
        set { mouthShape = newValue ? .open : .closed }
    }
    /// Mid-jump: progress 0..1 and height (30/gravity). Nil when grounded.
    public var jump: JumpState?
    /// A momentary somersault. Rotation reaches exactly ±360° while the
    /// character follows an exaggerated ballistic arc into its landed pose.
    public var flip: FlipState?
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

    public struct FlipState: Equatable, Sendable {
        public var progress: Double
        public var rotation: Double
        public var height: Double

        public init(progress: Double, rotation: Double, height: Double) {
            self.progress = progress
            self.rotation = rotation
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
                wobble: Double = 7, size: Double = 1, outfitAnim: [Int: OutfitAnim] = [:],
                leanTilt: Double? = nil, mouthShape: MouthShape? = nil,
                flip: FlipState? = nil) {
        self.x = x
        self.depth = depth
        self.phase = phase
        self.tilt = tilt
        self.leanTilt = leanTilt ?? tilt
        self.face = face
        self.eye = eye
        self.mouthShape = mouthShape ?? (talking ? .open : .closed)
        self.jump = jump
        self.flip = flip
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
        let base = Self.basePose(for: c, in: state, at: t)
        var resolved = base
        let definitions = Dictionary(state.reactionLibrary.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })

        // Later blocks win when two active reactions own the same channel.
        // Different channels compose, and every value is relative to the raw
        // performance so removing/ending a block reveals it unchanged.
        for instance in c.reactions.sorted(by: {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }) where instance.dur > 0 && t >= instance.start && t < instance.start + instance.dur {
            guard let definition = definitions[instance.reactionID], definition.dur > 0 else { continue }
            let localT = min(definition.dur,
                             max(0, (t - instance.start) * definition.dur / instance.dur))
            var performer = c
            performer.x = 0.5
            performer.depth = 0
            performer.face = base.face
            performer.baseOutfit = base.outfit
            performer.subs = []
            performer.clips = []
            performer.events = definition.events
            performer.reactions = []
            performer.wobble = base.wobble
            performer.size = base.size
            let motion = Self.motionRates(for: c, at: t)
            performer.speed = motion.speed
            performer.rotationSpeed = motion.rotationSpeed
            performer.recStart = StartPose(x: 0.5, depth: 0, face: base.face,
                                           spin: 0, zoom: 1)
            let reaction = Self.basePose(for: performer, in: state, at: localT)
            Self.overlay(reaction, definition: definition, intensity: instance.intensity,
                         on: &resolved, relativeTo: base)
        }
        return resolved
    }

    /// Pose from the character's ordinary event stream, before reaction blocks.
    private static func basePose(for c: Character, in state: SceneState,
                                 at t: Double) -> CharacterPose {
        // Checkpointed + cached: bit-identical to simulatePosition, but a
        // query costs ~10s of integration, not t — hour-long shows stay 60fps.
        let sim = PositionTimelineCache.shared.timeline(
            events: c.events,
            recStart: c.recStart ?? StartPose(x: c.x, depth: c.depth, face: c.face),
            speed: c.speed, rotationSpeed: c.rotationSpeed,
            gScale: state.gScale, coveringAtLeast: t)
            .pose(at: t)

        // State scan (web resetToTime): last-writer-wins over events strictly before t.
        var eye = EyeExpression.open
        var tilt = 0.0
        var tiltPrev = 0.0
        var tiltChangeT = -1000.0
        var manualMouthOpen = false
        var outfit = c.baseOutfit
        var wobble = c.wobble
        var size = c.size
        var lastOutfitChange: [Int: (t: Double, prev: String?)] = [:]
        var lastJumpDown: Double?
        var lastFlipDown: (time: Double, direction: Double)?
        var heldLeft = false, heldRight = false, heldUp = false, heldDown = false

        for ev in c.events {
            guard ev.t < t else { break }
            switch ev {
            case .motion(_, _, _, let w, let z):
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
                    case .keyM: manualMouthOpen = down
                    case .keyT: tiltPrev = tilt; tilt = down ? 9 : 0; tiltChangeT = te
                    case .keyB: tiltPrev = tilt; tilt = down ? -9 : 0; tiltChangeT = te
                    case .keyJ: if down { lastJumpDown = te }
                    case .keyF: if down { lastFlipDown = (te, 1) }
                    case .keyD: if down { lastFlipDown = (te, -1) }
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

        var flip: CharacterPose.FlipState?
        if let action = lastFlipDown {
            let safeGravity = max(0.1, state.gravity)
            let dur = (620.0 / safeGravity).rounded() / 1000.0
            let progress = (t - action.time) / dur
            if progress >= 0, progress < 1 {
                // Smoothstep gives the turn zero angular velocity at takeoff
                // and landing, an exact half-turn at the timeline midpoint,
                // and a complete 360° action.
                let eased = progress * progress * (3 - 2 * progress)
                flip = .init(
                    progress: progress,
                    rotation: action.direction * 360 * eased,
                    height: 38 / safeGravity)
            }
        }

        // Active caption: latest-starting subtitle covering t wins.
        var sub: Subtitle?
        for s in c.subs where t >= s.start && t < s.start + s.dur {
            if sub == nil || s.start > sub!.start { sub = s }
        }

        // Eased lean: tilt ramps to its target over 0.15s (ease-out) rather
        // than snapping. `tilt` stays the instant value for logic/fidelity.
        var leanTilt = tilt
        let sinceTilt = t - tiltChangeT
        if sinceTilt >= 0, sinceTilt < 0.15 {
            let e = sinceTilt / 0.15
            let k = 1 - e
            leanTilt = tiltPrev + (tilt - tiltPrev) * (1 - k * k * k)
        }

        // Pixel-chunk dissolve for any slot changed within the last 0.8s.
        var outfitAnim: [Int: CharacterPose.OutfitAnim] = [:]
        for (slot, change) in lastOutfitChange {
            let p = (t - change.t) / CharacterPose.outfitDissolve
            if p >= 0, p < 1 { outfitAnim[slot] = .init(prev: change.prev, progress: p) }
        }

        var mouthShape: MouthShape = .closed
        if c.speechVoice.automaticMouth {
            var activeClip: AudioClip?
            for clip in c.clips
            where !clip.mouthCues.isEmpty && t >= clip.start && t < clip.start + clip.dur {
                if let current = activeClip {
                    if clip.start >= current.start { activeClip = clip }
                } else {
                    activeClip = clip
                }
            }
            if let activeClip {
                mouthShape = activeClip.mouthShape(at: t) ?? .closed
            }
        }
        // A held M key is an explicit live/manual performance and wins over
        // generated lip sync. Releasing it hands control back to automation.
        if manualMouthOpen { mouthShape = .open }

        return CharacterPose(x: sim.x, depth: sim.depth, phase: sim.phase, tilt: tilt,
                             face: sim.face, eye: eye, talking: mouthShape != .closed, jump: jump,
                             outfit: outfit, activeSubtitle: sub?.text,
                             moving: heldLeft || heldRight || heldUp || heldDown,
                             spin: sim.spin, zoom: sim.zoom, wobble: wobble, size: size,
                             outfitAnim: outfitAnim, leanTilt: leanTilt,
                             mouthShape: mouthShape, flip: flip)
    }

    private static func overlay(_ reaction: CharacterPose,
                                definition: ReactionDefinition,
                                intensity rawIntensity: Double,
                                on result: inout CharacterPose,
                                relativeTo base: CharacterPose) {
        let intensity = min(4, max(0, rawIntensity))
        let groups = definition.ownedGroups

        if groups.contains(.move) {
            result.x = min(1, max(0, base.x + (reaction.x - 0.5) * intensity))
            result.face = reaction.face
        }
        if groups.contains(.depth) {
            result.depth = min(1, max(-12, base.depth + reaction.depth * intensity))
        }
        if groups.contains(.move) || groups.contains(.depth) {
            result.phase = reaction.phase
            result.moving = reaction.moving
        }
        if groups.contains(.tilt) {
            result.tilt = reaction.tilt * intensity
            result.leanTilt = reaction.leanTilt * intensity
        }
        if groups.contains(.talk) { result.talking = reaction.talking }
        if groups.contains(.blink) { result.eye = reaction.eye }
        if groups.contains(.jump) {
            result.jump = reaction.jump.map {
                CharacterPose.JumpState(progress: $0.progress, height: $0.height * intensity)
            }
            result.flip = reaction.flip.map {
                CharacterPose.FlipState(
                    progress: $0.progress,
                    rotation: $0.rotation * intensity,
                    height: $0.height * intensity)
            }
        }
        if groups.contains(.spin) {
            result.spin = base.spin + reaction.spin * intensity
        }
        if groups.contains(.zoom) {
            result.zoom = max(0.05, base.zoom * (1 + (reaction.zoom - 1) * intensity))
        }
        if definition.ownsWobble {
            result.wobble = max(0, base.wobble + (reaction.wobble - base.wobble) * intensity)
        }
        if definition.ownsSize {
            result.size = max(0.05, base.size + (reaction.size - base.size) * intensity)
        }

        for slot in definition.outfitSlots {
            if let item = reaction.outfit[slot] { result.outfit[slot] = item }
            else { result.outfit.removeValue(forKey: slot) }
            if let animation = reaction.outfitAnim[slot] { result.outfitAnim[slot] = animation }
            else { result.outfitAnim.removeValue(forKey: slot) }
        }
    }

    private static func motionRates(for character: Character, at t: Double)
        -> (speed: Double, rotationSpeed: Double) {
        var speed = character.speed
        var rotationSpeed = character.rotationSpeed
        for event in character.events {
            guard event.t < t else { break }
            if case .motion(_, let nextSpeed, let nextRotation, _, _) = event {
                if let nextSpeed { speed = nextSpeed }
                if let nextRotation { rotationSpeed = nextRotation }
            }
        }
        return (speed, rotationSpeed)
    }
}
