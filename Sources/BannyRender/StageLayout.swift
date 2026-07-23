import Foundation
import BannyCore

/// Pure layout math — the rendering half of the webapp's `step()` — mapping a
/// simulated pose to concrete stage transforms. Testable without drawing.
///
/// Coordinate model: the OUTPUT frame is 16:9 (what ships). The webapp's stage
/// box was slightly taller — aspect (16/9)·(1−0.038) — with the bottom strip
/// excluded from export, and all layout constants (ground 0.071, face margin
/// 0.078) are fractions of that taller virtual stage. We keep the same virtual
/// space so every constant carries over verbatim, then the renderer just crops:
/// `virtualHeight = outputHeight / (1 − 0.038)`.
public enum StageLayout {

    public static let trackStripFraction = 0.038
    /// Character art box (the 400×400 SVG canvas) and its foot pivot.
    public static let box = 400.0
    public static let footPivot = (x: 200.0, y: 328.0)

    public struct Placement: Equatable, Sendable {
        /// Top-left of the (scaled) 400-box in virtual-stage px.
        public var tx: Double
        public var ty: Double
        public var scale: Double
        /// Horizontal flip: 1 or -1, about the foot pivot.
        public var face: Int
        /// Gait offset (local 400-box units, applied inside the scaled box).
        public var bobY: Double
        /// Total artwork rotation in degrees, retained for editor overlays and diagnostics.
        public var rotation: Double
        /// Components are retained separately because grounded rotation and
        /// flips may use different pivots even though `rotation` remains the
        /// convenient total for editor overlays and diagnostics.
        public var gaitRotation: Double
        public var spinRotation: Double
        public var flipRotation: Double
        /// World-space displacement of the artwork center caused only by the
        /// flip around its selected pivot. The light pass uses this to keep the
        /// ground shadow attached when a custom pivot swings the body sideways.
        public var flipCenterOffsetX: Double
        public var flipCenterOffsetY: Double
        /// 0 grounded → 1 at the flip apex. Shared with the shadow pass.
        public var flipLift: Double
        /// Gravity-weighted landing compression. Zero while airborne and
        /// after recovery; roughly 1 at a normal-gravity impact.
        public var landingImpact: Double
        /// Painter's-order key: round((2 - depth) * 100).
        public var zIndex: Int
        /// Foot X in virtual-stage px (anchor for shadows/tags).
        public var footX: Double
        /// Foot Y in virtual-stage px.
        public var footY: Double
    }

    public struct ShadowPlacement: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var scaleX: Double
        public var scaleY: Double
        public var opacity: Double
        public var zIndex: Int
    }

    /// Web `.shadow` element: 150×34 px rendering of the 32×7 shadow art.
    public static let shadowSize = (width: 150.0, height: 34.0)

    public static func virtualHeight(outputHeight: Double) -> Double {
        outputHeight / (1 - trackStripFraction)
    }

    /// Exaggerated cartoon-ballistic flip arc. The fast launch reaches an early
    /// apex, hangs high while the turn continues, then gravity takes over and
    /// brings the feet down before the final compression/recovery frames.
    /// This is shared by artwork and shadow layout so they cannot drift apart.
    static func flipLiftFactor(progress: Double, gravity: Double = 1) -> Double {
        let p = min(1, max(0, progress))
        let apex = 0.34
        let contact = 0.92
        if p <= apex {
            let phase = p / apex
            return 1 - pow(1 - phase, 3.2)
        }
        guard p < contact else { return 0 }
        let phase = (p - apex) / (contact - apex)
        let safeGravity = min(4, max(0.25, gravity))
        let curve = min(5.2, max(3.0, 3.9 + 0.55 * log2(safeGravity)))
        return 1 - pow(phase, curve)
    }

    /// Brief foot-anchored squash after contact. In real time the pulse is
    /// already shorter at high gravity because flip duration is 1/gravity;
    /// this weight also makes its amplitude read as a harder impact.
    static func flipLandingImpact(progress: Double, gravity: Double = 1) -> Double {
        let p = min(1, max(0, progress))
        let contact = 0.92
        guard p > contact, p < 1 else { return 0 }
        let phase = (p - contact) / (1 - contact)
        let pulse: Double
        if phase < 0.28 {
            let compression = phase / 0.28
            pulse = 1 - pow(1 - compression, 2.2)
        } else {
            let recovery = (phase - 0.28) / 0.72
            pulse = pow(1 - recovery, 1.4)
        }
        let weight = min(1.6, max(0.55, pow(max(0.1, gravity), 0.35)))
        return pulse * weight
    }

    /// Explicit pivot in 400×400 artwork coordinates. Keeping this conversion
    /// beside the layout math prevents the character and shadow passes from
    /// disagreeing about clamping or coordinate space.
    static func explicitRotationPivot(for character: Character) -> (x: Double, y: Double)? {
        character.rotationPivot.map {
            (x: min(1, max(0, $0.x)) * box,
             y: min(1, max(0, $0.y)) * box)
        }
    }

    /// Port of the render section of web `step()` (verbatim constants).
    public static func place(pose: CharacterPose, character: Character, scene: SceneState,
                             stageWidth W: Double, virtualHeight H: Double) -> Placement {
        let dFar = max(0, pose.depth)
        // pose.size/pose.wobble are the time-resolved motion params (base value
        // overridden by any timed .motion changes before t).
        let scale = pose.size * scene.gSize * (1 - pose.depth * scene.gScale) * (H / 900)
            * max(0.05, pose.zoom)
        let lift = dFar * H * 0.42
        let footX = pose.x * W

        let closer = max(0, -pose.depth)
        let feetScreenY = (H - H * 0.071 - lift) + closer * (H * 0.09)
        let tx = footX - 200 * scale
        var ty = feetScreenY - 0.82 * box * scale

        // Keep the face (~y150 in the box) on screen; feet may leave the bottom.
        let faceY = ty + 150 * scale
        let margin = H * 0.078
        if faceY < margin { ty += margin - faceY }
        else if faceY > H - margin { ty -= faceY - (H - margin) }

        let bob = pose.moving ? -abs(sin(pose.phase)) * pose.wobble : 0
        let sway = pose.moving ? sin(pose.phase) * 2.5 : 0
        var jumpLift = 0.0
        var jumpWob = 0.0
        if let jump = pose.jump {
            jumpLift = sin(jump.progress * .pi) * jump.height
            jumpWob = sin(jump.progress * .pi * 3) * 2.5 * (1 - jump.progress)
        }
        let flipLift = pose.flip.map {
            flipLiftFactor(progress: $0.progress, gravity: scene.gravity)
        } ?? 0
        let flipLiftAmount = pose.flip.map { flipLift * $0.height } ?? 0
        let landingImpact = pose.flip.map {
            flipLandingImpact(progress: $0.progress, gravity: scene.gravity)
        } ?? 0
        let airLift = max(jumpLift, flipLiftAmount)
        let gaitRotation = sway + pose.leanTilt + jumpWob
        let flipRotation = pose.flip?.rotation ?? 0
        let flipPivot = explicitRotationPivot(for: character)
            ?? (x: box / 2, y: box / 2)
        let center = (x: box / 2, y: box / 2)
        let flipRadians = flipRotation * .pi / 180
        let localFlipOffset = (
            x: (center.x - flipPivot.x) * cos(flipRadians)
                - (center.y - flipPivot.y) * sin(flipRadians)
                + flipPivot.x - center.x,
            y: (center.x - flipPivot.x) * sin(flipRadians)
                + (center.y - flipPivot.y) * cos(flipRadians)
                + flipPivot.y - center.y
        )
        // Spin and gait are outside the flip transform in the renderer, so
        // rotate the flip-only displacement through those layers as a vector.
        let outerRadians = (pose.spin + gaitRotation) * .pi / 180
        var flipCenterOffsetX = (localFlipOffset.x * cos(outerRadians)
            - localFlipOffset.y * sin(outerRadians)) * scale
        let flipCenterOffsetY = (localFlipOffset.x * sin(outerRadians)
            + localFlipOffset.y * cos(outerRadians)) * scale
        // Facing mirrors the already-rotated artwork around its vertical axis.
        flipCenterOffsetX *= Double(pose.face)

        return Placement(tx: tx, ty: ty, scale: scale, face: pose.face,
                         bobY: bob - airLift,
                         rotation: gaitRotation + pose.spin + flipRotation,
                         gaitRotation: gaitRotation,
                         spinRotation: pose.spin,
                         flipRotation: flipRotation,
                         flipCenterOffsetX: flipCenterOffsetX,
                         flipCenterOffsetY: flipCenterOffsetY,
                         flipLift: flipLift,
                         landingImpact: landingImpact,
                         zIndex: Int(((2 - pose.depth) * 100).rounded()),
                         footX: footX, footY: ty + footPivot.y * scale)
    }

    /// Port of web `step()`'s per-light shadow block.
    public static func shadow(for placement: Placement, pose: CharacterPose, light: Light,
                              stageWidth W: Double, virtualHeight H: Double) -> ShadowPlacement {
        let lx = light.x * W
        let ly = light.y * H
        let hx = placement.footX - lx
        let vy = max(40, (H - H * 0.071) - ly)
        let ang = min(1, abs(hx) / vy)
        var cx = placement.footX + hx * (0.04 + ang * 0.12)
        let dFar = max(0, pose.depth)
        let zin = min(1, max(0, -pose.depth) / 6)
        // Airborne motion shrinks and fades the shadow. During a flip, its
        // center also projects away from the active light by the artwork's
        // actual lift, and follows any drift caused by a custom rotation pivot.
        // 0 grounded → 1 at apex.
        let jumpLift = pose.jump.map { sin($0.progress * .pi) } ?? 0
        let lift = max(jumpLift, placement.flipLift)
        let airShrink = 1 - 0.2 * lift
        let airFade = 1 - 0.35 * lift
        if let flip = pose.flip {
            let liftPixels = placement.flipLift * flip.height * placement.scale
            let casterLift = max(0, liftPixels - placement.flipCenterOffsetY)
            cx += placement.flipCenterOffsetX + hx / vy * casterLift
        }
        // A 90°/270° pose presents the tall sprite broadside to the floor.
        // Widen and flatten the footprint, returning continuously to the
        // grounded proportions at 0°/360°.
        let flipBroadside = abs(sin(placement.flipRotation * .pi / 180))
        let flipWidth = 1 + 0.35 * flipBroadside
        let flipDepth = 1 - 0.12 * flipBroadside
        // Wobble: the gait sway rocks the shadow side to side under the feet.
        let sway = pose.moving ? sin(pose.phase) * 6 * placement.scale : 0
        // Tilt: leaning forward/back nudges the shadow slightly with the lean.
        let tiltShift = pose.leanTilt * 1.1 * placement.scale
        cx += sway + tiltShift
        let impact = placement.landingImpact
        return ShadowPlacement(
            x: cx - 75,
            y: placement.footY - H * 0.019,
            scaleX: placement.scale * (0.7 + ang * 0.8) * airShrink
                * flipWidth * (1 + 0.16 * impact),
            scaleY: placement.scale * 0.75 * airShrink * flipDepth
                * (1 + 0.07 * impact),
            opacity: max(0, (0.42 - ang * 0.30) * (1 - dFar * 0.7))
                * (1 - zin) * airFade * (1 + 0.28 * impact),
            zIndex: placement.zIndex - 1)
    }

    /// Caption font size: web `--capfs = max(12, round(h*0.033))`.
    public static func captionFontSize(virtualHeight H: Double) -> Double {
        max(12, (H * 0.033).rounded())
    }
}
