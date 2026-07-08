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
        FrameRenderer(assets: catalog).draw(scene: scene, at: 2.25, size: size, in: ctx)
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
