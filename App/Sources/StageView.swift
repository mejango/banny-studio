import SwiftUI
import ImageIO
import BannyCore
import BannyRender

/// The live stage: FrameRenderer output driven by the transport clock.
/// Identical draw path to export — what you see is what ships.
struct StageView: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile

    @State private var bgCache = BackgroundCache()
    @State private var dragLast: CGSize?
    @State private var stageSize: CGSize = .init(width: 1280, height: 720)

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                // Drive the clock from the render loop.
                model.tick(now: Date.timeIntervalSinceReferenceDate)
                model.freeformNudge(dt: 1 / 60)
                let scene = model.scene
                let sceneID = model.document.scenes[model.activeSceneIndex].id
                let bg = bgCache.image(for: sceneID, spec: scene.background, file: file)
                context.withCGContext { cg in
                    FrameRenderer(assets: SharedAssets.catalog).draw(
                        scene: scene, at: model.time, size: size,
                        background: bg, showSuns: !model.playing, in: cg)
                }
                drawSelectionTags(context: context, size: size, scene: scene)
                DispatchQueue.main.async { stageSize = size }
                _ = timeline.date
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.black)
        .gesture(characterDrag)
    }

    /// Number badges under each character (editor-only, like the web's tag row).
    private func drawSelectionTags(context: GraphicsContext, size: CGSize, scene: SceneState) {
        let W = Double(size.width)
        let H = StageLayout.virtualHeight(outputHeight: Double(size.height))
        let sim = model.simulator
        for i in scene.characters.indices {
            let pose = sim.pose(characterIndex: i, at: model.time)
            let x = pose.x * W
            let y = Double(size.height) - 12
            let label = Text("\((i + 1) % 10)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(model.selection.contains(i) ? Color.orange : Color.gray)
            context.draw(label, at: CGPoint(x: x, y: y))
            _ = H
        }
    }

    /// Drag a character while paused: horizontal = start X, vertical = depth
    /// (up = farther), mirroring the web's idle drag.
    private var characterDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !model.playing, !model.recording else { return }
                guard let i = model.selection.first, model.scene.characters.indices.contains(i) else { return }
                let prev = dragLast ?? .zero
                let dx = value.translation.width - prev.width
                let dy = value.translation.height - prev.height
                dragLast = value.translation
                var c = model.scene.characters[i]
                c.x = min(1 - 0.044, max(0.044, c.x + dx / stageSize.width))
                c.depth = min(1, max(-12, c.depth - dy / 120)) // up = farther, web drag feel
                if model.time < 0.1 {
                    c.recStart = StartPose(x: c.x, depth: c.depth, face: c.face)
                }
                model.scene.characters[i] = c
            }
            .onEnded { _ in dragLast = nil }
    }
}

/// Decodes and caches per-scene background media.
@Observable
final class BackgroundCache {
    private var cache: [String: (image: CGImage, crop: Crop)] = [:]
    private var failed: Set<String> = []

    func image(for sceneID: String, spec: BackgroundSpec?, file: ShowDocumentFile) -> (image: CGImage, crop: Crop)? {
        guard let spec else { return nil }
        let crop: Crop
        switch spec {
        case .image(_, let c): crop = c
        case .video(_, let c): crop = c // static poster frame for now; video bg is a later polish
        }
        if let hit = cache[sceneID] { return (hit.image, crop) }
        guard !failed.contains(sceneID), case .image = spec,
              let media = file.backgrounds[sceneID],
              let src = CGImageSourceCreateWithData(media.data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            failed.insert(sceneID)
            return nil
        }
        cache[sceneID] = (img, crop)
        return (img, crop)
    }
}
