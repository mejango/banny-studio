import Foundation
import CoreGraphics
import CoreImage
import CoreText
import BannyCore

/// Draws one frame of a scene into a CGContext — the same code path for the live
/// editor stage and the exporter. Everything derives from `SceneSimulator` poses,
/// so a frame is a pure function of (scene, t, size).
public struct FrameRenderer: Sendable {

    /// Web export canvas fill.
    public static let stageFill = CGColor(red: 1, green: 0.992, blue: 0.949, alpha: 1) // #fffdf2

    let assets: AssetCatalog
    /// Slot render order between BODY layers, per web RENDER constant.
    private static let renderOrder: [Slot] = [
        .outfit(2), .body, .outfit(3), .outfit(4), .eyes, .outfit(6), .mouth,
        .outfit(8), .outfit(9), .outfit(10), .outfit(11), .outfit(12), .outfit(13),
    ]

    private enum Slot {
        case body, eyes, mouth
        case outfit(Int)
    }

    public init(assets: AssetCatalog) {
        self.assets = assets
    }

    /// Renders scene state at time t into `ctx`. `size` is the output frame (16:9).
    /// `background`: pre-decoded background image, drawn per its crop mode.
    /// `visualAsset`: resolves the exact frame for a floating still/GIF/video cue.
    /// `imageAsset` remains as the static-image fallback for existing callers.
    ///
    /// Coordinate contract: `ctx` must have a TOP-LEFT origin (SwiftUI's
    /// GraphicsContext already does). For a raw bottom-left CGBitmapContext
    /// (export, tests), pass `flipped: true`.
    public func draw(scene: SceneState, at t: Double, size: CGSize,
                     background: (image: CGImage, crop: Crop)? = nil,
                     imageAsset: ((String) -> CGImage?)? = nil,
                     visualAsset: ((ImageCue, Double) -> CGImage?)? = nil,
                     poseOverride: ((Int, CharacterPose) -> CharacterPose)? = nil,
                     flipped: Bool = false,
                     in ctx: CGContext) {
        let W = Double(size.width)
        let outH = Double(size.height)
        let H = StageLayout.virtualHeight(outputHeight: outH)
        let sim = SceneSimulator(state: scene)

        ctx.saveGState()
        if flipped {
            ctx.translateBy(x: 0, y: CGFloat(outH))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.interpolationQuality = .none // pixel art stays crisp

        ctx.setFillColor(Self.stageFill)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: outH))

        // Virtual camera: the active scene cue's pan/zoom applies to the whole
        // world (background, images, shadows, characters) — captions stay put.
        ctx.saveGState()
        if var cam = scene.activeBackgroundCue(at: t)?.camera(at: t) {
            if let background {
                // The frame never sees past the background's edges.
                let r = Self.backgroundRect(imageWidth: background.image.width,
                                            imageHeight: background.image.height,
                                            crop: background.crop,
                                            size: CGSize(width: W, height: outH))
                cam = Self.clampCamera(cam, background: r, size: CGSize(width: W, height: outH))
            }
            let z = max(0.1, cam.zoom)
            ctx.translateBy(x: CGFloat(W / 2), y: CGFloat(outH / 2))
            ctx.scaleBy(x: CGFloat(z), y: CGFloat(z))
            ctx.translateBy(x: CGFloat(-cam.x * W), y: CGFloat(-cam.y * outH))
        }
        if let background {
            drawBackground(background.image, crop: background.crop, size: CGSize(width: W, height: outH), in: ctx)
        }
        let lights = scene.activeLights(at: t)

        // Image cues (between backdrop and characters) — image tracks and the
        // image cues living on media (audio) tracks.
        if imageAsset != nil || visualAsset != nil {
            var visualTracks: [(hidden: Bool, presence: [VisibilityEvent], cues: [ImageCue])] =
                scene.imageTracks.map { ($0.hidden, $0.presence, $0.cues) }
            visualTracks += scene.audioTracks.map { ($0.hidden, $0.presence, $0.cues) }
            for track in visualTracks where !track.hidden && track.presence.isPresent(at: t) {
                for cue in track.cues where t >= cue.start && t < cue.start + cue.dur {
                    guard let img = visualAsset?(cue, t) ?? imageAsset?(cue.assetID) else { continue }
                    let p = cue.placement(at: t)
                    drawMedia(img, cue: cue, placement: p, lights: lights,
                              stageWidth: W, stageHeight: outH, in: ctx)
                }
            }
        }

        // Poses + placements for every character, painter-sorted by depth.
        var entries: [(index: Int, pose: CharacterPose, placement: StageLayout.Placement)] = []
        for i in scene.characters.indices
            where !scene.characters[i].hidden && scene.characters[i].presence.isPresent(at: t) {
            var pose = sim.pose(characterIndex: i, at: t)
            if let poseOverride { pose = poseOverride(i, pose) }
            let placement = StageLayout.place(pose: pose, character: scene.characters[i],
                                              scene: scene, stageWidth: W, virtualHeight: H)
            entries.append((i, pose, placement))
        }

        // Shadows first (web z = char z - 1, under every character).
        if let shadow = assets.shadowImage() {
            for e in entries.sorted(by: { $0.placement.zIndex < $1.placement.zIndex }) {
                for light in lights where light.intensity > 0.01 {
                    let s = StageLayout.shadow(for: e.placement, pose: e.pose,
                                               light: Light(x: light.x, y: light.y),
                                               stageWidth: W, virtualHeight: H)
                    guard s.opacity > 0 else { continue }
                    // Bigger lights cast wider shadows (120 = neutral).
                    // Size never changes darkness — intensity owns that.
                    let f = light.size / 120
                    let widen = 0.85 + 0.15 * f
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(s.opacity * light.intensity))
                    ctx.translateBy(x: CGFloat(s.x + 75), y: CGFloat(s.y + StageLayout.shadowSize.height / 2))
                    ctx.scaleBy(x: CGFloat(s.scaleX * widen), y: CGFloat(s.scaleY))
                    drawImage(shadow, in: CGRect(x: -75, y: -StageLayout.shadowSize.height / 2,
                                                 width: StageLayout.shadowSize.width,
                                                 height: StageLayout.shadowSize.height), ctx: ctx)
                    ctx.restoreGState()
                }
            }
        }

        for e in entries.sorted(by: { $0.placement.zIndex < $1.placement.zIndex }) {
            drawCharacter(scene.characters[e.index], pose: e.pose, placement: e.placement, in: ctx)
        }
        ctx.restoreGState() // camera off — captions render in screen space

        // Captions gate on track visibility only — a presence-hidden character
        // still speaks (its audio plays), so its line still shows.
        var captionLines: [(speaker: Character, text: String)] = []
        for i in scene.characters.indices where !scene.characters[i].hidden {
            let pose = entries.first(where: { $0.index == i })?.pose
                ?? sim.pose(characterIndex: i, at: t)
            if let text = pose.activeSubtitle {
                captionLines.append((scene.characters[i], text))
            }
        }
        drawCaptions(captionLines, W: W, outH: outH, H: H, in: ctx)

        ctx.restoreGState()
    }

    // MARK: - Floating media

    private final class MediaEffectContext: @unchecked Sendable {
        private let context = CIContext(options: [.cacheIntermediates: true])
        private let lock = NSLock()

        func image(_ image: CIImage, from rect: CGRect) -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return context.createCGImage(image, from: rect)
        }
    }

    private static let mediaEffectContext = MediaEffectContext()

    /// Color controls and alpha-fringe cleanup are raster effects, so they are
    /// applied once to the resolved still/GIF/video frame before placement.
    private func adjustedMediaImage(_ image: CGImage, appearance a: MediaAppearance) -> CGImage {
        let hasColorControls = abs(a.brightness) > 0.0001 || abs(a.contrast - 1) > 0.0001
            || abs(a.saturation - 1) > 0.0001
        let hasTint = a.tintAmount > 0.0001
        let hasCleanup = a.cleanup > 0.0001
        guard hasColorControls || hasTint || hasCleanup else { return image }

        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var output = CIImage(cgImage: image)
        if hasColorControls {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: min(1, max(-1, a.brightness)),
                kCIInputContrastKey: min(2, max(0, a.contrast)),
                kCIInputSaturationKey: min(2, max(0, a.saturation)),
            ])
        }
        if hasTint {
            let amount = min(1, max(0, a.tintAmount))
            let color = CIColor(red: min(1, max(0, a.tint.red)),
                                green: min(1, max(0, a.tint.green)),
                                blue: min(1, max(0, a.tint.blue)), alpha: amount)
            let overlay = CIImage(color: color).cropped(to: extent)
            output = overlay.applyingFilter("CISourceAtopCompositing", parameters: [
                kCIInputBackgroundImageKey: output,
            ])
        }
        if hasCleanup {
            // Raise the alpha contrast and push faint matte/fringe pixels to
            // transparent while keeping solid artwork opaque.
            let amount = min(1, max(0, a.cleanup))
            let gain = 1 + amount * 6
            let bias = -amount * 0.32
            output = output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: gain),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: bias),
            ])
        }
        return Self.mediaEffectContext.image(output, from: extent) ?? image
    }

    /// Solid black carrying only the source alpha, used by outlines and the
    /// light-aware shadow pass.
    private func mediaSilhouette(_ image: CGImage) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let output = CIImage(cgImage: image).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        return Self.mediaEffectContext.image(output, from: extent)
    }

    private func mediaMaskPath(_ mask: MediaMask, radius: Double, rect: CGRect) -> CGPath? {
        guard mask != .none else { return nil }
        let path = CGMutablePath()
        switch mask {
        case .none:
            return nil
        case .rectangle:
            path.addRect(rect)
        case .roundedRectangle:
            let r = min(rect.width, rect.height) * min(0.5, max(0, radius))
            path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
        case .circle:
            let side = min(rect.width, rect.height)
            path.addEllipse(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                                       width: side, height: side))
        }
        return path
    }

    private func drawMedia(_ source: CGImage, cue: ImageCue, placement p: ImagePlacement,
                           lights: [ResolvedLight], stageWidth W: Double, stageHeight H: Double,
                           in ctx: CGContext) {
        let image = adjustedMediaImage(source, appearance: cue.appearance)
        let w = p.scale * W
        let h = w * Double(image.height) / Double(max(1, image.width))
        let pivotX = min(1, max(0, cue.pivot.x))
        let pivotY = min(1, max(0, cue.pivot.y))
        let rect = CGRect(x: -pivotX * w, y: -pivotY * h, width: w, height: h)
        let anchorX = p.x * W
        let anchorY = p.y * H
        let angle = p.rotation * .pi / 180
        let silhouetteNeeded = cue.appearance.outline > 0.01 || cue.appearance.shadow > 0.001
        let silhouette = silhouetteNeeded ? mediaSilhouette(image) : nil

        // The media's visual center can differ from its anchor. Shadows move
        // away from every active light, using that true center as the caster.
        if cue.appearance.shadow > 0.001, let silhouette {
            let localCenterX = (0.5 - pivotX) * w
            let localCenterY = (0.5 - pivotY) * h
            let centerX = anchorX + cos(angle) * localCenterX - sin(angle) * localCenterY
            let centerY = anchorY + sin(angle) * localCenterX + cos(angle) * localCenterY
            for light in lights where light.intensity > 0.01 {
                var vx = centerX - light.x * W
                var vy = centerY - light.y * H
                let length = hypot(vx, vy)
                if length < 0.001 { vx = 0; vy = 1 }
                else { vx /= length; vy /= length }
                let spread = 0.65 + min(2, max(0.2, light.size / 120)) * 0.35
                let distance = max(4, min(w, h) * 0.08) * spread
                let alpha = min(0.7, max(0, cue.appearance.shadow)
                    * max(0, light.intensity) * 0.46)
                ctx.saveGState()
                ctx.translateBy(x: anchorX + vx * distance, y: anchorY + vy * distance)
                ctx.rotate(by: CGFloat(angle))
                if let path = mediaMaskPath(cue.mask, radius: cue.maskRadius, rect: rect) {
                    ctx.addPath(path)
                    ctx.clip()
                }
                ctx.setAlpha(alpha)
                drawImage(silhouette, in: rect, ctx: ctx)
                ctx.restoreGState()
            }
        }

        ctx.saveGState()
        ctx.translateBy(x: anchorX, y: anchorY)
        ctx.rotate(by: CGFloat(angle))
        let outline = max(0, cue.appearance.outline) * W / 1920
        if outline > 0.05, let silhouette {
            if let path = mediaMaskPath(cue.mask, radius: cue.maskRadius, rect: rect) {
                ctx.addPath(path)
                ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
                ctx.setLineWidth(outline * 2)
                ctx.strokePath()
            } else {
                for step in 0..<12 {
                    let a = Double(step) / 12 * 2 * Double.pi
                    drawImage(silhouette,
                              in: rect.offsetBy(dx: cos(a) * outline, dy: sin(a) * outline),
                              ctx: ctx)
                }
            }
        }
        if let path = mediaMaskPath(cue.mask, radius: cue.maskRadius, rect: rect) {
            ctx.addPath(path)
            ctx.clip()
        }
        drawImage(image, in: rect, ctx: ctx)
        ctx.restoreGState()
    }

    // MARK: - Character

    private func drawCharacter(_ character: Character, pose: CharacterPose,
                               placement p: StageLayout.Placement, in ctx: CGContext) {
        ctx.saveGState()
        // .char: translate(tx,ty) scale(s), origin 0 0
        ctx.translateBy(x: CGFloat(p.tx), y: CGFloat(p.ty))
        ctx.scaleBy(x: CGFloat(p.scale), y: CGFloat(p.scale))
        // .facing: scaleX(face) about the foot pivot
        let pivot = StageLayout.footPivot
        if p.face == -1 {
            ctx.translateBy(x: CGFloat(pivot.x), y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.translateBy(x: CGFloat(-pivot.x), y: 0)
        }
        // Vertical motion is shared, but rotational layers keep independent
        // pivots: gait/lean stays grounded; free rotation honors the chosen
        // pivot; Auto flips around the body center for a clean somersault.
        ctx.translateBy(x: 0, y: CGFloat(p.bobY))
        func rotate(_ degrees: Double, around point: (x: Double, y: Double)) {
            guard abs(degrees) > 0.000_001 else { return }
            ctx.translateBy(x: CGFloat(point.x), y: CGFloat(point.y))
            ctx.rotate(by: CGFloat(degrees * .pi / 180))
            ctx.translateBy(x: CGFloat(-point.x), y: CGFloat(-point.y))
        }
        rotate(p.gaitRotation, around: pivot)
        let explicitPivot = StageLayout.explicitRotationPivot(for: character)
        rotate(p.spinRotation, around: explicitPivot ?? StageLayout.footPivot)
        rotate(p.flipRotation, around: explicitPivot
               ?? (x: StageLayout.box / 2, y: StageLayout.box / 2))
        // Contact lands at the feet, then briefly compresses the body instead
        // of driving it through the floor. The matching shadow spread makes
        // the same two or three frames read as a physical thump.
        if p.landingImpact > 0.000_001 {
            let squashX = 1 + 0.045 * p.landingImpact
            let squashY = max(0.82, 1 - 0.09 * p.landingImpact)
            ctx.translateBy(x: CGFloat(pivot.x), y: CGFloat(pivot.y))
            ctx.scaleBy(x: CGFloat(squashX), y: CGFloat(squashY))
            ctx.translateBy(x: CGFloat(-pivot.x), y: CGFloat(-pivot.y))
        }

        let box = CGRect(x: 0, y: 0, width: StageLayout.box, height: StageLayout.box)
        let outfit = pose.outfit
        let headWorn = outfit[4] != nil
        // Web applyOutfit exclusivity: suit hides suit bottom/top; head hides glasses/head top.
        var hidden = Set<Int>()
        if headWorn { hidden.formUnion([6, 12]) }
        if outfit[9] != nil { hidden.formUnion([10, 11]) }

        for slot in Self.renderOrder {
            switch slot {
            case .body:
                if let img = assets.bodyImage(character.body) { drawImage(img, in: box, ctx: ctx) }
            case .eyes:
                guard !headWorn else { continue }
                let option = outfit[5] ?? "default"
                if let img = assets.eyesImage(option: option, expression: pose.eye, body: character.body) {
                    drawImage(img, in: box, ctx: ctx)
                }
            case .mouth:
                guard !headWorn else { continue }
                let option = outfit[7] ?? "default"
                let entry = assets.mouth(option: option)
                var shape = pose.mouthShape
                if entry?.inverted == true {
                    if shape == .open { shape = .closed }
                    else if shape == .closed { shape = .open }
                }
                let state: AssetCatalog.MouthState
                switch shape {
                case .open: state = .open
                case .tight: state = .tight
                case .closed: state = .closed
                }
                if let img = assets.mouthImage(option: option, state: state,
                                               body: character.body) {
                    drawImage(img, in: box, ctx: ctx)
                }
            case .outfit(let id):
                guard !hidden.contains(id) else { continue }
                let anim = pose.outfitAnim[id]
                let currentName = outfit[id]
                if let anim {
                    // banny-minter "fuzz": 4 stepped frames, each an independent
                    // random scatter of 4px chunks at ramping density.
                    let n = Self.fuzzSteps
                    let step = min(n - 1, max(0, Int(anim.progress * Double(n))))
                    if let name = currentName, let img = assets.outfitImage(name, body: character.body) {
                        // Equip / swap-in: density climbs 0.2→0.8, then snaps full.
                        let density = Double(step + 1) / Double(n) * Self.fuzzMaxDensity
                        withFuzzClip(box: box, seed: id * 131 + step, density: density, ctx: ctx) {
                            drawImage(img, in: box, ctx: ctx)
                        }
                    } else if let prev = anim.prev,
                              let pimg = assets.outfitImage(prev, body: character.body) {
                        // Unequip: density falls 0.8→0.2, then gone.
                        let density = Double(n - step) / Double(n) * Self.fuzzMaxDensity
                        withFuzzClip(box: box, seed: id * 131 + step, density: density, ctx: ctx) {
                            drawImage(pimg, in: box, ctx: ctx)
                        }
                    } else if id == 3, let img = assets.necklaceImage(body: character.body) {
                        drawImage(img, in: box, ctx: ctx)
                    }
                } else if id == 3, currentName == nil {
                    // Necklace slot falls back to the default block chain.
                    if let img = assets.necklaceImage(body: character.body) {
                        drawImage(img, in: box, ctx: ctx)
                    }
                } else if let name = currentName, let img = assets.outfitImage(name, body: character.body) {
                    drawImage(img, in: box, ctx: ctx)
                }
            }
        }
        ctx.restoreGState()
    }

    // MARK: - Outfit "fuzz" dissolve (ported from banny-minter useFuzz)

    /// Frames in the dissolve (banny-minter fuzzStepCount).
    static let fuzzSteps = 4
    /// Peak coverage before the mask is dropped and the item snaps to full.
    private static let fuzzMaxDensity = 0.8
    /// Chunk size in the 400 art box (banny-minter pixelSize = 4 → 100×100 grid).
    private static let fuzzPixel = 4.0

    /// A stable pseudo-random value in [0,1) for a chunk in a given frame seed.
    private func chunkHash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: x) &* 374761393
        h = h &+ UInt64(truncatingIfNeeded: y) &* 668265263
        h = h &+ UInt64(truncatingIfNeeded: seed) &* 2246822519
        h ^= h >> 15; h = h &* 2654435761; h ^= h >> 13
        return Double(h % 100_000) / 100_000.0
    }

    /// Reveals `draw` through a fresh random scatter of chunks covering
    /// `density` of the box (0 = nothing, 1 = full). `seed` re-rolls per frame
    /// so the scatter flickers between steps like the web fuzz.
    private func withFuzzClip(box: CGRect, seed: Int, density: Double,
                              ctx: CGContext, _ draw: () -> Void) {
        if density >= 0.999 { draw(); return }
        if density <= 0.001 { return }
        let n = max(1, Int((box.width / CGFloat(Self.fuzzPixel)).rounded()))
        let cw = box.width / CGFloat(n), ch = box.height / CGFloat(n)
        let path = CGMutablePath()
        for gy in 0..<n {
            for gx in 0..<n where chunkHash(gx, gy, seed) < density {
                path.addRect(CGRect(x: box.minX + CGFloat(gx) * cw, y: box.minY + CGFloat(gy) * ch,
                                    width: cw + 0.6, height: ch + 0.6))
            }
        }
        if path.isEmpty { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        draw()
        ctx.restoreGState()
    }

    // MARK: - Camera bounds

    /// Where the background lands in frame coordinates (before any camera).
    public static func backgroundRect(imageWidth: Int, imageHeight: Int, crop: Crop,
                                      size: CGSize) -> CGRect {
        let W = size.width, H = size.height
        let iw = CGFloat(imageWidth), ih = CGFloat(imageHeight)
        switch crop {
        case .stretch, .tile:
            return CGRect(x: 0, y: 0, width: W, height: H)
        case .cover, .fit:
            let s = crop == .cover ? max(W / iw, H / ih) : min(W / iw, H / ih)
            return CGRect(x: (W - iw * s) / 2, y: (H - ih * s) / 2, width: iw * s, height: ih * s)
        }
    }

    /// The camera pinned so the frame never shows space outside the
    /// background rect `r` — zoom bottoms out at the background bounds and
    /// the focus can't drag an edge into view.
    public static func clampCamera(_ cam: CameraState, background r: CGRect,
                                   size: CGSize) -> CameraState {
        let W = Double(size.width), H = Double(size.height)
        guard W > 0, H > 0, r.width > 0, r.height > 0 else { return cam }
        var out = cam
        // ponytail: zMin capped at 4 so a tiny fit-cropped image can't force absurd zoom
        let zMin = min(4, max(W / Double(r.width), H / Double(r.height)))
        let z = max(max(0.1, cam.zoom), zMin)
        out.zoom = z
        let loX = Double(r.minX) / W + 1 / (2 * z)
        let hiX = Double(r.maxX) / W - 1 / (2 * z)
        out.x = hiX < loX ? (loX + hiX) / 2 : min(hiX, max(loX, cam.x))
        let loY = Double(r.minY) / H + 1 / (2 * z)
        let hiY = Double(r.maxY) / H - 1 / (2 * z)
        out.y = hiY < loY ? (loY + hiY) / 2 : min(hiY, max(loY, cam.y))
        return out
    }

    // MARK: - Background

    func drawBackground(_ image: CGImage, crop: Crop, size: CGSize, in ctx: CGContext) {
        let W = size.width, H = size.height
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        switch crop {
        case .stretch:
            drawImage(image, in: CGRect(x: 0, y: 0, width: W, height: H), ctx: ctx)
        case .cover, .fit:
            let s = crop == .cover ? max(W / iw, H / ih) : min(W / iw, H / ih)
            let w = iw * s, h = ih * s
            drawImage(image, in: CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h), ctx: ctx)
        case .tile:
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H))
            var y: CGFloat = 0
            while y < H {
                var x: CGFloat = 0
                while x < W {
                    drawImage(image, in: CGRect(x: x, y: y, width: iw, height: ih), ctx: ctx)
                    x += iw
                }
                y += ih
            }
            ctx.restoreGState()
        }
    }

    // MARK: - Captions

    /// Fixed bottom-center subtitle stack (web capbar): black box, up to 2 lines,
    /// colored speaker bar per line.
    private func drawCaptions(_ lines: [(speaker: Character, text: String)],
                              W: Double, outH: Double, H: Double, in ctx: CGContext) {
        guard !lines.isEmpty else { return }
        let fontSize = StageLayout.captionFontSize(virtualHeight: H)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let pad = fontSize * 0.45
        let lineHeight = fontSize * 1.35
        let shown = Array(lines.suffix(2))

        // Measure widest line.
        var ctLines: [(CTLine, Character)] = []
        var maxWidth = 0.0
        for line in shown {
            let attr = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ])
            let ct = CTLineCreateWithAttributedString(attr)
            maxWidth = max(maxWidth, CTLineGetTypographicBounds(ct, nil, nil, nil))
            ctLines.append((ct, line.speaker))
        }

        let boxW = min(maxWidth + pad * 2, W * 0.9)
        let boxH = Double(shown.count) * lineHeight + pad
        let boxX = (W - boxW) / 2
        let boxY = outH - boxH - outH * 0.02

        ctx.setFillColor(CGColor(gray: 0, alpha: 0.82))
        ctx.fill(CGRect(x: boxX, y: boxY, width: boxW, height: boxH))

        for (i, (ct, _)) in ctLines.enumerated() {
            let y = boxY + pad * 0.7 + Double(i) * lineHeight + fontSize
            ctx.saveGState()
            // CoreText draws in unflipped coords; flip locally around the baseline.
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: boxX + pad, y: y)
            CTLineDraw(ct, ctx)
            ctx.restoreGState()
        }
    }

    func bodyColor(_ body: Body) -> CGColor {
        switch body {
        case .orange: return CGColor(red: 1, green: 0.486, blue: 0.008, alpha: 1)      // #ff7c02
        case .original: return CGColor(red: 1, green: 0.780, blue: 0, alpha: 1)        // #ffc700
        case .pink: return CGColor(red: 1, green: 0.588, blue: 0.663, alpha: 1)        // #ff96a9
        case .alien: return CGColor(red: 0.188, green: 0.635, blue: 0.125, alpha: 1)   // #30a220
        }
    }

    /// Draws an image with top-left-origin rect semantics inside our flipped context.
    private func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }
}
