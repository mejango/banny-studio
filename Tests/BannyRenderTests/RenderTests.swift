import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import BannyRender
import BannyCore

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let assetsRoot = repoRoot.appendingPathComponent("App/Resources/BannyAssets")

private func makeContext(_ size: CGSize) -> CGContext {
    CGContext(data: nil, width: Int(size.width), height: Int(size.height),
              bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

@Test func layoutMatchesWebMath() {
    // A default character at x=0.5, depth 0, H=900 → scale = H/900 = 1, feet on the ground line.
    let c = Character(body: .orange)
    let pose = CharacterPose(x: 0.5, depth: 0, phase: 0, tilt: 0, face: 1, eye: .open,
                             talking: false, jump: nil, outfit: [:], activeSubtitle: nil, moving: false)
    let p = StageLayout.place(pose: pose, character: c, scene: SceneState(),
                              stageWidth: 1600, virtualHeight: 900)
    #expect(p.scale == 1)
    #expect(p.footX == 800)
    #expect(p.tx == 600) // footX - 200*scale
    // feetScreenY = 900 - 63.9 = 836.1; ty = 836.1 - 328 = 508.1
    let expectedTy: Double = 900.0 - 900.0 * 0.071 - 0.82 * 400.0
    #expect(abs(p.ty - expectedTy) < 1e-9)
    #expect(p.zIndex == 200)

    // Depth 1 with gScale 0.6 shrinks: scale = 1*(1-0.6) = 0.4, z falls behind.
    let far = CharacterPose(x: 0.5, depth: 1, phase: 0, tilt: 0, face: 1, eye: .open,
                            talking: false, jump: nil, outfit: [:], activeSubtitle: nil, moving: false)
    let pf = StageLayout.place(pose: far, character: c, scene: SceneState(),
                               stageWidth: 1600, virtualHeight: 900)
    #expect(abs(pf.scale - 0.4) < 1e-9)
    #expect(pf.zIndex == 100)
    #expect(pf.ty < p.ty) // lifted toward the horizon
}

@Test func groundPlaneSpeedIsContinuousAsFeetEnterTheFrame() {
    let character = Character(body: .orange)
    let scene = SceneState(gScale: 0.35, gSize: 1.2)
    func footY(_ depth: Double) -> Double {
        let pose = CharacterPose(
            x: 0.5, depth: depth, phase: 0, tilt: 0, face: 1, eye: .open,
            talking: false, jump: nil, outfit: [:], activeSubtitle: nil, moving: false)
        return StageLayout.place(
            pose: pose,
            character: character,
            scene: scene,
            stageWidth: 1_600,
            virtualHeight: 900).footY
    }

    let epsilon = 0.001
    let atPlane = footY(0)
    let nearStep = footY(-epsilon) - atPlane
    let farStep = atPlane - footY(epsilon)
    #expect(abs(nearStep - farStep) < 0.002)
    #expect(StageLayout.farGroundLiftFraction(depth: 0) == 0)
    #expect(abs(StageLayout.farGroundLiftFraction(depth: 1) - 0.42) < 1e-12)
}

@Test func captionLayoutRespondsToFrameAspectAndStaysTitleSafe() throws {
    let text = "Former Chelsea hero, newly promoted"
    let landscape = try #require(CaptionLayoutEngine.layout(
        texts: [text],
        frameWidth: 1_512,
        outputHeight: 850))
    let portrait = try #require(CaptionLayoutEngine.layout(
        texts: [text],
        frameWidth: 478,
        outputHeight: 850))

    #expect(landscape.lines.map(\.text) == [text])
    #expect(portrait.lines.count == 2)
    #expect(portrait.lines.map(\.text).joined(separator: " ") == text)
    #expect(portrait.boxX >= 478 * 0.069)
    #expect(portrait.boxX + portrait.boxWidth <= 478 * 0.931)
    #expect(portrait.boxY + portrait.boxHeight <= 850 * 0.951)

    // Wrapping is preferred; only denser copy reduces the common type size.
    let dense = Array(repeating: "precision production", count: 5).joined(separator: " ")
    let reduced = try #require(CaptionLayoutEngine.layout(
        texts: [dense],
        frameWidth: 478,
        outputHeight: 850))
    let counts = Dictionary(grouping: reduced.lines, by: \.captionIndex).values.map(\.count)
    #expect(reduced.fontSize < portrait.fontSize)
    #expect(counts.allSatisfy { $0 <= 2 })
}

@Test func captionLayoutScalesIdenticallyBetweenPreviewAndExport() throws {
    let text = "Former Chelsea hero, newly promoted"
    let preview = try #require(CaptionLayoutEngine.layout(
        texts: [text],
        frameWidth: 540,
        outputHeight: 960))
    let export = try #require(CaptionLayoutEngine.layout(
        texts: [text],
        frameWidth: 1_080,
        outputHeight: 1_920))

    #expect(preview.lines.map(\.text) == export.lines.map(\.text))
    #expect(abs(export.fontSize - preview.fontSize * 2) < 0.01)
    #expect(abs(export.boxWidth - preview.boxWidth * 2) < 0.01)
    #expect(abs(export.boxHeight - preview.boxHeight * 2) < 0.01)
    #expect(abs(export.boxX - preview.boxX * 2) < 0.01)
    #expect(abs(export.boxY - preview.boxY * 2) < 0.01)
}

@Test func captionRendererConfinesPortraitTextToSafeFrame() throws {
    let catalog = try AssetCatalog(assetsRoot: assetsRoot)
    let size = CGSize(width: 360, height: 640)
    let scene = SceneState(characters: [
        Character(
            body: .orange,
            subs: [Subtitle(
                text: "Former Chelsea hero, newly promoted",
                start: 0,
                dur: 1)],
            presence: [VisibilityEvent(t: 0, visible: false)]),
    ])
    let context = makeContext(size)
    FrameRenderer(assets: catalog).draw(
        scene: scene,
        at: 0.25,
        size: size,
        flipped: true,
        in: context)
    let image = try #require(context.makeImage())
    if let output = ProcessInfo.processInfo.environment["CAPTION_TEST_OUT"] {
        try writePNG(image, to: URL(fileURLWithPath: output))
    }
    let bytes = try #require(image.dataProvider?.data as Data?)

    var minDarkX = Int.max
    var maxDarkX = Int.min
    var darkPixels = 0
    for y in 0..<image.height {
        for x in 0..<image.width {
            let index = y * image.bytesPerRow + x * 4
            if bytes[index] < 80,
               bytes[index + 1] < 80,
               bytes[index + 2] < 80,
               bytes[index + 3] > 100 {
                minDarkX = min(minDarkX, x)
                maxDarkX = max(maxDarkX, x)
                darkPixels += 1
            }
        }
    }

    #expect(darkPixels > 0)
    #expect(minDarkX >= Int((Double(image.width) * 0.069).rounded(.down)))
    #expect(maxDarkX <= Int((Double(image.width) * 0.931).rounded(.up)))
}

@Test func zoomScalesAndSpinRotatesPlacement() {
    let c = Character(body: .orange)
    func place(spin: Double, zoom: Double) -> StageLayout.Placement {
        let pose = CharacterPose(x: 0.5, depth: 0, phase: 0, tilt: 0, face: 1, eye: .open,
                                 talking: false, jump: nil, outfit: [:], activeSubtitle: nil,
                                 moving: false, spin: spin, zoom: zoom)
        return StageLayout.place(pose: pose, character: c, scene: SceneState(),
                                 stageWidth: 1600, virtualHeight: 900)
    }
    let base = place(spin: 0, zoom: 1)
    let zoomed = place(spin: 0, zoom: 2)
    #expect(abs(zoomed.scale - base.scale * 2) < 1e-9) // zoom multiplies scale
    let spun = place(spin: 30, zoom: 1)
    #expect(abs((spun.rotation - base.rotation) - 30) < 1e-9) // spin adds to rotation
    #expect(spun.spinRotation == 30)
    #expect(spun.gaitRotation == 0)
    #expect(spun.flipRotation == 0)
    #expect(spun.scale == base.scale) // spin doesn't touch scale
}

@Test func flipPlacementUsesBallisticLiftAndSeparateFullRotation() {
    let character = Character(body: .orange)
    let pose = CharacterPose(
        x: 0.5, depth: 0, phase: 0, tilt: 0, face: 1, eye: .open,
        talking: false, jump: nil, outfit: [:], activeSubtitle: nil,
        moving: false,
        flip: .init(progress: 0.5, rotation: 180, height: 60))
    let placement = StageLayout.place(
        pose: pose,
        character: character,
        scene: SceneState(),
        stageWidth: 1_600,
        virtualHeight: 900)

    let expectedLift = StageLayout.flipLiftFactor(progress: 0.5) * 60
    #expect(abs(placement.bobY + expectedLift) < 1e-9)
    #expect(placement.gaitRotation == 0)
    #expect(placement.spinRotation == 0)
    #expect(placement.flipRotation == 180)
    #expect(placement.rotation == 180)
    #expect(abs(placement.flipCenterOffsetX) < 1e-9)
    #expect(abs(placement.flipCenterOffsetY) < 1e-9)
    #expect(placement.landingImpact == 0)
}

@Test func flipLiftUsesAnExaggeratedLaunchAndAcceleratingLanding() {
    let lift: (Double) -> Double = {
        StageLayout.flipLiftFactor(progress: $0)
    }
    #expect(lift(0) == 0)
    #expect(lift(0.34) == 1)
    #expect(lift(0.9) > 0)
    #expect(lift(0.92) == 0)
    #expect(lift(1) == 0)
    #expect(lift(0.15) > sin(0.15 * .pi)) // crisper takeoff than the old sine arc
    #expect(lift(0.1) > 0.65)
    #expect(lift(0.25) > 0.98) // most clearance arrives early, before the apex
    let earlyDescent = lift(0.78) - lift(0.85)
    let landingDescent = lift(0.85) - lift(0.92)
    #expect(landingDescent > earlyDescent)

    let impact: (Double) -> Double = {
        StageLayout.flipLandingImpact(progress: $0)
    }
    #expect(impact(0.92) == 0)
    #expect(impact(0.95) > 0.8)
    #expect(impact(1) == 0)
    #expect(StageLayout.flipLandingImpact(progress: 0.95, gravity: 2) > impact(0.95))
    #expect(StageLayout.flipLandingImpact(progress: 0.95, gravity: 0.5) < impact(0.95))

    let impactPose = CharacterPose(
        x: 0.5, depth: 0, phase: 0, tilt: 0, face: 1, eye: .open,
        talking: false, jump: nil, outfit: [:], activeSubtitle: nil, moving: false,
        flip: .init(progress: 0.95, rotation: 359, height: 60))
    let character = Character(body: .orange)
    let soft = StageLayout.place(
        pose: impactPose, character: character,
        scene: SceneState(gravity: 0.5),
        stageWidth: 1_600, virtualHeight: 900)
    let hard = StageLayout.place(
        pose: impactPose, character: character,
        scene: SceneState(gravity: 2),
        stageWidth: 1_600, virtualHeight: 900)
    #expect(hard.landingImpact > soft.landingImpact)
}

@Test func flipShadowTracksTheLightArcAndBroadsideSilhouette() {
    let character = Character(body: .orange)
    let groundedPose = CharacterPose(
        x: 0.5, depth: 0, phase: 0, tilt: 0, face: 1, eye: .open,
        talking: false, jump: nil, outfit: [:], activeSubtitle: nil, moving: false)
    let flipPose = CharacterPose(
        x: 0.5, depth: 0, phase: 0, tilt: 0, face: 1, eye: .open,
        talking: false, jump: nil, outfit: [:], activeSubtitle: nil, moving: false,
        flip: .init(progress: 0.25, rotation: 90, height: 60))
    let light = Light(x: 0.1, y: 0.1)
    let groundedPlacement = StageLayout.place(
        pose: groundedPose, character: character, scene: SceneState(),
        stageWidth: 1_600, virtualHeight: 900)
    let flipPlacement = StageLayout.place(
        pose: flipPose, character: character, scene: SceneState(),
        stageWidth: 1_600, virtualHeight: 900)
    let grounded = StageLayout.shadow(
        for: groundedPlacement, pose: groundedPose, light: light,
        stageWidth: 1_600, virtualHeight: 900)
    let airborne = StageLayout.shadow(
        for: flipPlacement, pose: flipPose, light: light,
        stageWidth: 1_600, virtualHeight: 900)

    #expect(airborne.x > grounded.x) // lift projects farther away from the left-side light
    #expect(airborne.scaleX > grounded.scaleX) // horizontal body widens the footprint
    #expect(airborne.scaleY < grounded.scaleY)
    #expect(airborne.opacity < grounded.opacity)

    let landedPose = CharacterPose(
        x: 0.5, depth: 0, phase: 0, tilt: 0, face: 1, eye: .open,
        talking: false, jump: nil, outfit: [:], activeSubtitle: nil, moving: false,
        flip: .init(progress: 1, rotation: 360, height: 60))
    let landedPlacement = StageLayout.place(
        pose: landedPose, character: character, scene: SceneState(),
        stageWidth: 1_600, virtualHeight: 900)
    let landed = StageLayout.shadow(
        for: landedPlacement, pose: landedPose, light: light,
        stageWidth: 1_600, virtualHeight: 900)
    #expect(abs(landed.x - grounded.x) < 1e-9)
    #expect(abs(landed.scaleX - grounded.scaleX) < 1e-9)
    #expect(abs(landed.scaleY - grounded.scaleY) < 1e-9)
    #expect(abs(landed.opacity - grounded.opacity) < 1e-9)

    let impactPose = CharacterPose(
        x: 0.5, depth: 0, phase: 0, tilt: 0, face: 1, eye: .open,
        talking: false, jump: nil, outfit: [:], activeSubtitle: nil, moving: false,
        flip: .init(progress: 0.95, rotation: 359, height: 60))
    let impactPlacement = StageLayout.place(
        pose: impactPose, character: character, scene: SceneState(),
        stageWidth: 1_600, virtualHeight: 900)
    let impact = StageLayout.shadow(
        for: impactPlacement, pose: impactPose, light: light,
        stageWidth: 1_600, virtualHeight: 900)
    #expect(impactPlacement.landingImpact > 0.8)
    #expect(impact.scaleX > grounded.scaleX)
    #expect(impact.scaleY > grounded.scaleY)
    #expect(impact.opacity > grounded.opacity)
}

@Test func flipShadowFollowsCustomPivotDriftAndFacing() {
    let character = Character(body: .orange, rotationPivot: .characterHead)
    func placement(rotation: Double, face: Int) -> StageLayout.Placement {
        let pose = CharacterPose(
            x: 0.5, depth: 0, phase: 0, tilt: 0, face: face, eye: .open,
            talking: false, jump: nil, outfit: [:], activeSubtitle: nil, moving: false,
            flip: .init(progress: 0.25, rotation: rotation, height: 60))
        return StageLayout.place(
            pose: pose, character: character, scene: SceneState(),
            stageWidth: 1_600, virtualHeight: 900)
    }

    let front = placement(rotation: 90, face: 1)
    let back = placement(rotation: -90, face: 1)
    let mirrored = placement(rotation: 90, face: -1)
    #expect(front.flipCenterOffsetX < 0)
    #expect(back.flipCenterOffsetX > 0)
    #expect(abs(mirrored.flipCenterOffsetX + front.flipCenterOffsetX) < 1e-9)
}

@Test func shadowOpacityFadesWithDepthAndAngle() {
    let c = Character(body: .orange)
    let pose = CharacterPose(x: 0.5, depth: 0, phase: 0, tilt: 0, face: 1, eye: .open,
                             talking: false, jump: nil, outfit: [:], activeSubtitle: nil, moving: false)
    let p = StageLayout.place(pose: pose, character: c, scene: SceneState(),
                              stageWidth: 1600, virtualHeight: 900)
    // Light directly overhead → ang≈?; hx = 800-800=0 → ang 0 → opacity 0.42.
    let overhead = StageLayout.shadow(for: p, pose: pose, light: Light(x: 0.5, y: 0.1),
                                      stageWidth: 1600, virtualHeight: 900)
    #expect(abs(overhead.opacity - 0.42) < 1e-9)
    // Side light increases angle → dimmer, offset shadow.
    let side = StageLayout.shadow(for: p, pose: pose, light: Light(x: 0.05, y: 0.1),
                                  stageWidth: 1600, virtualHeight: 900)
    #expect(side.opacity < overhead.opacity)
    #expect(side.x + 75 > p.footX) // shadow pushed away from the light
}

@Test func assetCatalogResolvesEveryPart() throws {
    let catalog = try AssetCatalog(assetsRoot: assetsRoot)
    for body in Body.allCases {
        #expect(catalog.bodyImage(body) != nil, Comment(rawValue: "\(body)"))
        #expect(catalog.necklaceImage(body: body) != nil)
        for eye in ["default", "eyeliner", "fierce", "glassy", "surprised", "introspective"] {
            for expr in [EyeExpression.open, .closed, .brow1, .brow2] {
                #expect(catalog.eyesImage(option: eye, expression: expr, body: body) != nil,
                        Comment(rawValue: "\(eye)/\(expr)/\(body)"))
            }
        }
        for mouth in ["default", "lipstick", "gapteeth", "open"] {
            for state in [AssetCatalog.MouthState.open, .tight, .closed] {
                #expect(catalog.mouthImage(option: mouth, state: state, body: body) != nil,
                        Comment(rawValue: "\(mouth)/\(state)/\(body)"))
            }
        }
    }
    #expect(catalog.catalog.outfits.count == 52)
    for (name, entry) in catalog.catalog.outfits {
        #expect(catalog.outfitImage(name, body: .orange) != nil, Comment(rawValue: name))
        #expect((2...13).contains(entry.slot))
    }
    #expect(catalog.shadowImage() != nil)
    #expect(catalog.sunImage() != nil)
}

@Test func rendersFrameDeterministically() throws {
    let catalog = try AssetCatalog(assetsRoot: assetsRoot)
    let renderer = FrameRenderer(assets: catalog)
    let scene = SceneState(
        characters: [
            Character(body: .orange, x: 0.3,
                      baseOutfit: [5: "fierce", 6: "proff-glasses", 11: "doc-coat", 12: "proff-hair"],
                      events: [.key(t: 0, code: .arrowRight, down: true),
                               .key(t: 1.5, code: .arrowRight, down: false),
                               .key(t: 2, code: .keyM, down: true)],
                      name: "DARL",
                      recStart: StartPose(x: 0.3, depth: 0, face: 1)),
            Character(body: .alien, x: 0.7, depth: 0.5, face: -1,
                      subs: [Subtitle(text: "greetings", start: 1, dur: 5)]),
        ],
        lights: [Light(x: 0.8, y: 0.18)])

    let size = CGSize(width: 1280, height: 720)
    func render() throws -> CGImage {
        let ctx = makeContext(size)
        FrameRenderer(assets: catalog).draw(scene: scene, at: 2.25, size: size, flipped: true, in: ctx)
        return try #require(ctx.makeImage())
    }
    let a = try render()
    let b = try render()
    #expect(a.dataProvider?.data as Data? == b.dataProvider?.data as Data?, "render must be deterministic")

    // Persist for visual inspection / snapshot reference.
    let out = ProcessInfo.processInfo.environment["RENDER_TEST_OUT"]
    if let out {
        try writePNG(a, to: URL(fileURLWithPath: out))
    }
    _ = renderer
}

@Test func floatingVisualResolverReceivesCueAndShowTime() throws {
    let catalog = try AssetCatalog(assetsRoot: assetsRoot)
    let cue = ImageCue(id: "visual", assetID: "movie", start: 2, dur: 4,
                       from: ImagePlacement())
    let scene = SceneState(audioTracks: [
        AudioTrack(id: "media", name: "Media", cues: [cue]),
    ])
    let source = makeContext(CGSize(width: 2, height: 2))
    source.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    source.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let image = try #require(source.makeImage())
    var resolvedCue: ImageCue?
    var resolvedTime: Double?

    let context = makeContext(CGSize(width: 100, height: 100))
    FrameRenderer(assets: catalog).draw(
        scene: scene, at: 3.25, size: CGSize(width: 100, height: 100),
        visualAsset: { cue, time in
            resolvedCue = cue
            resolvedTime = time
            return image
        },
        flipped: true, in: context)

    #expect(resolvedCue == cue)
    #expect(resolvedTime == 3.25)
}

@Test func mediaMaskTintPivotAndLightShadowRenderTogether() throws {
    let catalog = try AssetCatalog(assetsRoot: assetsRoot)
    let sourceContext = makeContext(CGSize(width: 10, height: 10))
    sourceContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    sourceContext.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    let source = try #require(sourceContext.makeImage())
    var cue = ImageCue(
        id: "styled", assetID: "asset", start: 0, dur: 2,
        from: ImagePlacement(x: 0.2, y: 0.2, scale: 0.2),
        appearance: MediaAppearance(
            tint: MediaColor(red: 0, green: 0, blue: 1), tintAmount: 1,
            outline: 12, shadow: 1),
        mask: .circle, pivot: .topLeft)

    func render(lights: [Light]) throws -> CGImage {
        let context = makeContext(CGSize(width: 100, height: 100))
        let scene = SceneState(imageTracks: [
            ImageTrack(id: "media", name: "Media", cues: [cue]),
        ], lights: lights)
        FrameRenderer(assets: catalog).draw(
            scene: scene, at: 0.1, size: CGSize(width: 100, height: 100),
            visualAsset: { _, _ in source }, flipped: true, in: context)
        return try #require(context.makeImage())
    }

    let withoutLight = try render(lights: [])
    let withLight = try render(lights: [Light(x: 0, y: 0)])
    #expect(withoutLight.dataProvider?.data as Data? != withLight.dataProvider?.data as Data?)

    let bytes = try #require(withoutLight.dataProvider?.data as Data?)
    var bluePixels = 0
    var minBlueX = Int.max
    for y in 0..<withoutLight.height {
        for x in 0..<withoutLight.width {
            let i = y * withoutLight.bytesPerRow + x * 4
            if bytes[i + 2] > 180, bytes[i] < 80 {
                bluePixels += 1
                minBlueX = min(minBlueX, x)
            }
        }
    }
    #expect(bluePixels > 220 && bluePixels < 380) // circular crop, not the 20×20 square
    #expect(minBlueX >= 19) // top-left pivot places its leading edge at x=20

    cue.appearance.cleanup = 0.7 // exercise the alpha-cleanup filter in the same draw path
    _ = try render(lights: [])
}

@Test func cameraClampsToBackgroundBounds() {
    // Wide 32:9 image cover-cropped into a 9:16 frame: bg exactly frame height,
    // much wider than the frame.
    let size = CGSize(width: 900, height: 1600)
    let r = FrameRenderer.backgroundRect(imageWidth: 3200, imageHeight: 900,
                                         crop: .cover, size: size)
    #expect(abs(r.height - 1600) < 1e-6)
    #expect(r.width > size.width)

    // Zoom below 1 would show above/below the background → pinned to 1,
    // and vertical focus pinned to center.
    let out = FrameRenderer.clampCamera(CameraState(x: 0.5, y: 0.9, zoom: 0.6),
                                        background: r, size: size)
    #expect(abs(out.zoom - 1) < 1e-9)
    #expect(abs(out.y - 0.5) < 1e-9)

    // Panning far past the edge stops exactly AT the background's left edge:
    // the bg's left lands on the frame's left (frame coord 0), not inside it.
    let left = FrameRenderer.clampCamera(CameraState(x: -5, y: 0.5, zoom: 1),
                                         background: r, size: size)
    let frameLeft = 1 * (Double(r.minX) - left.x * 900) + 450
    #expect(abs(frameLeft) < 1e-6)

    // A legal camera passes through untouched.
    let ok = CameraState(x: 0.5, y: 0.5, zoom: 2)
    #expect(FrameRenderer.clampCamera(ok, background: r, size: size) == ok)
}

@Test func gifSequencePicksFramesByTime() throws {
    // 3 frames (red, green, blue) at 0.2s each, built in memory.
    let colors: [CGColor] = [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                             CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                             CGColor(red: 0, green: 0, blue: 1, alpha: 1)]
    let data = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(
        data, UTType.gif.identifier as CFString, colors.count, nil))
    for color in colors {
        let ctx = makeContext(CGSize(width: 8, height: 8))
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, frameProps as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(dest))

    let seq = try #require(GifSequence(data: data as Data))
    #expect(seq.frames.count == 3)
    #expect(abs(seq.duration - 0.6) < 1e-6)
    func red(at t: Double) -> UInt8 {
        let img = seq.frame(at: t)
        let d = img.dataProvider!.data! as Data
        return d[0]
    }
    #expect(red(at: 0.0) > 200)   // frame 1: red
    #expect(red(at: 0.3) < 50)    // frame 2: green
    #expect(red(at: 0.7) > 200)   // loops back to red
    // Static image (single frame) is not a sequence.
    let png = makeContext(CGSize(width: 4, height: 4))
    png.setFillColor(colors[0])
    png.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let pngData = NSMutableData()
    let pdest = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(pdest, png.makeImage()!, nil)
    CGImageDestinationFinalize(pdest)
    #expect(GifSequence(data: pngData as Data) == nil)
}

@Test func cameraZoomScalesTheWorld() throws {
    let catalog = try AssetCatalog(assetsRoot: assetsRoot)
    // One character dead center, and a scene cue whose camera zooms 2× into
    // the frame center. The zoomed render must differ from the plain one, and
    // its center column must show the character's body color spanning ~2× the
    // vertical extent of the plain render's.
    func scene(camera: CameraState?) -> SceneState {
        SceneState(characters: [Character(body: .orange, x: 0.5)],
                   backgroundTracks: [BackgroundTrack(id: "bt", name: "Scenes", cues: [
                       BackgroundCue(id: "bc", assetID: "missing", start: 0, dur: 10,
                                     camFrom: camera),
                   ])],
                   lights: [Light(x: 0.8, y: 0.18)])
    }

    let size = CGSize(width: 1280, height: 720)
    func bodyPixels(_ scene: SceneState) throws -> Int {
        let ctx = makeContext(size)
        FrameRenderer(assets: catalog).draw(scene: scene, at: 0, size: size, flipped: true, in: ctx)
        let img = try #require(ctx.makeImage())
        let data = try #require(img.dataProvider?.data as Data?)
        let bpr = img.bytesPerRow
        var count = 0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let i = y * bpr + x * 4
                // Orange body: strongly red, low blue (RGBA).
                if data[i] > 180, data[i + 2] < 90 { count += 1 }
            }
        }
        return count
    }

    let plain = try bodyPixels(scene(camera: nil))
    // Focus on the character (standing low in the frame), zoom 2×.
    let zoomed = try bodyPixels(scene(camera: CameraState(x: 0.5, y: 0.8, zoom: 2)))
    #expect(plain > 0)
    #expect(Double(zoomed) > Double(plain) * 2, "zoom 2 on the character should grow its pixel area")

    // No camera == identity camera: explicitly-default camera renders identically.
    func render(_ s: SceneState) throws -> Data? {
        let ctx = makeContext(size)
        FrameRenderer(assets: catalog).draw(scene: s, at: 0, size: size, flipped: true, in: ctx)
        return try #require(ctx.makeImage()).dataProvider?.data as Data?
    }
    #expect(try render(scene(camera: nil)) == render(scene(camera: CameraState())))
}
