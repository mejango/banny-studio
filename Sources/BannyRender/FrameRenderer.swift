import Foundation
import CoreGraphics
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
    ///
    /// Coordinate contract: `ctx` must have a TOP-LEFT origin (SwiftUI's
    /// GraphicsContext already does). For a raw bottom-left CGBitmapContext
    /// (export, tests), pass `flipped: true`.
    public func draw(scene: SceneState, at t: Double, size: CGSize,
                     background: (image: CGImage, crop: Crop)? = nil,
                     imageAsset: ((String) -> CGImage?)? = nil,
                     showSuns: Bool = false,
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
        if let background {
            drawBackground(background.image, crop: background.crop, size: CGSize(width: W, height: outH), in: ctx)
        }

        // Image cues (between backdrop and characters).
        if let imageAsset {
            for track in scene.imageTracks where !track.hidden && track.presence.isPresent(at: t) {
                for cue in track.cues where t >= cue.start && t < cue.start + cue.dur {
                    guard let img = imageAsset(cue.assetID) else { continue }
                    let p = cue.placement(at: t)
                    let w = p.scale * W
                    let h = w * Double(img.height) / Double(max(1, img.width))
                    drawImage(img, in: CGRect(x: p.x * W - w / 2, y: p.y * outH - h / 2,
                                              width: w, height: h), ctx: ctx)
                }
            }
        }

        // Poses + placements for every character, painter-sorted by depth.
        var entries: [(index: Int, pose: CharacterPose, placement: StageLayout.Placement)] = []
        for i in scene.characters.indices
            where !scene.characters[i].hidden && scene.characters[i].presence.isPresent(at: t) {
            let pose = sim.pose(characterIndex: i, at: t)
            let placement = StageLayout.place(pose: pose, character: scene.characters[i],
                                              scene: scene, stageWidth: W, virtualHeight: H)
            entries.append((i, pose, placement))
        }

        // Shadows first (web z = char z - 1, under every character).
        if let shadow = assets.shadowImage() {
            for e in entries.sorted(by: { $0.placement.zIndex < $1.placement.zIndex }) {
                for light in scene.lights {
                    let s = StageLayout.shadow(for: e.placement, pose: e.pose, light: light,
                                               stageWidth: W, virtualHeight: H)
                    guard s.opacity > 0 else { continue }
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(s.opacity))
                    ctx.translateBy(x: CGFloat(s.x + 75), y: CGFloat(s.y + StageLayout.shadowSize.height / 2))
                    ctx.scaleBy(x: CGFloat(s.scaleX), y: CGFloat(s.scaleY))
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

        if showSuns, let sun = assets.sunImage() {
            let sunSize = 120.0 // editor-only affordance; lightSize slider drives the app UI value
            for light in scene.lights {
                drawImage(sun, in: CGRect(x: light.x * W - sunSize / 2, y: light.y * H - sunSize / 2,
                                          width: sunSize, height: sunSize), ctx: ctx)
            }
        }

        drawCaptions(entries.compactMap { entry in
            entry.pose.activeSubtitle.map { (speaker: scene.characters[entry.index], text: $0) }
        }, W: W, outH: outH, H: H, in: ctx)

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
        // .gait: translateY(bob) rotate(deg) about the foot pivot
        ctx.translateBy(x: 0, y: CGFloat(p.bobY))
        ctx.translateBy(x: CGFloat(pivot.x), y: CGFloat(pivot.y))
        ctx.rotate(by: CGFloat(p.rotation * .pi / 180))
        ctx.translateBy(x: CGFloat(-pivot.x), y: CGFloat(-pivot.y))

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
                let open = (entry?.inverted ?? false) ? !pose.talking : pose.talking
                if let img = assets.mouthImage(option: option, state: open ? .open : .closed,
                                               body: character.body) {
                    drawImage(img, in: box, ctx: ctx)
                }
            case .outfit(let id):
                guard !hidden.contains(id) else { continue }
                if id == 3 {
                    // Necklace slot falls back to the default block chain.
                    if let name = outfit[3], let img = assets.outfitImage(name, body: character.body) {
                        drawImage(img, in: box, ctx: ctx)
                    } else if let img = assets.necklaceImage(body: character.body) {
                        drawImage(img, in: box, ctx: ctx)
                    }
                } else if let name = outfit[id], let img = assets.outfitImage(name, body: character.body) {
                    drawImage(img, in: box, ctx: ctx)
                }
            }
        }
        ctx.restoreGState()
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

        let boxW = min(maxWidth + pad * 2 + 8, W * 0.9)
        let boxH = Double(shown.count) * lineHeight + pad
        let boxX = (W - boxW) / 2
        let boxY = outH - boxH - outH * 0.02

        ctx.setFillColor(CGColor(gray: 0, alpha: 0.82))
        ctx.fill(CGRect(x: boxX, y: boxY, width: boxW, height: boxH))

        for (i, (ct, speaker)) in ctLines.enumerated() {
            let y = boxY + pad * 0.7 + Double(i) * lineHeight + fontSize
            // Speaker color bar.
            ctx.setFillColor(bodyColor(speaker.body))
            ctx.fill(CGRect(x: boxX + 3, y: y - fontSize, width: 4, height: fontSize * 1.1))
            ctx.saveGState()
            // CoreText draws in unflipped coords; flip locally around the baseline.
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: boxX + pad + 8, y: y)
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
