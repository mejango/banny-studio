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
        /// Gait rotation in degrees about the foot pivot (sway + tilt + jump wobble).
        public var rotation: Double
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

    /// Port of the render section of web `step()` (verbatim constants).
    public static func place(pose: CharacterPose, character: Character, scene: SceneState,
                             stageWidth W: Double, virtualHeight H: Double) -> Placement {
        let dFar = max(0, pose.depth)
        let scale = character.size * scene.gSize * (1 - pose.depth * scene.gScale) * (H / 900)
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

        let bob = pose.moving ? -abs(sin(pose.phase)) * character.wobble : 0
        let sway = pose.moving ? sin(pose.phase) * 2.5 : 0
        var jumpY = 0.0
        var jumpWob = 0.0
        if let jump = pose.jump {
            jumpY = -sin(jump.progress * .pi) * jump.height
            jumpWob = sin(jump.progress * .pi * 3) * 2.5 * (1 - jump.progress)
        }

        return Placement(tx: tx, ty: ty, scale: scale, face: pose.face,
                         bobY: bob + jumpY, rotation: sway + pose.tilt + jumpWob,
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
        let cx = placement.footX + hx * (0.04 + ang * 0.12)
        let dFar = max(0, pose.depth)
        let zin = min(1, max(0, -pose.depth) / 6)
        return ShadowPlacement(
            x: cx - 75,
            y: placement.footY - H * 0.019,
            scaleX: placement.scale * (0.7 + ang * 0.8),
            scaleY: placement.scale * 0.75,
            opacity: max(0, (0.42 - ang * 0.30) * (1 - dFar * 0.7)) * (1 - zin),
            zIndex: placement.zIndex - 1)
    }

    /// Caption font size: web `--capfs = max(12, round(h*0.033))`.
    public static func captionFontSize(virtualHeight H: Double) -> Double {
        max(12, (H * 0.033).rounded())
    }
}
