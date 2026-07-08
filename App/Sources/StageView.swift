import SwiftUI
import ImageIO
import AVFoundation
import BannyCore
import BannyRender

/// The live stage: FrameRenderer output driven by the transport clock.
/// Identical draw path to export — what you see is what ships.
struct StageView: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile

    @State private var media = StageMediaCache()
    @State private var dragLast: CGSize?
    @State private var stageSize: CGSize = .init(width: 1280, height: 720)

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                model.tick(now: Date.timeIntervalSinceReferenceDate)
                model.freeformNudge(dt: 1 / 60)
                file.audioEngine?.tick(model: model)
                let scene = model.scene
                let bg = scene.activeBackgroundCue(at: model.time).flatMap {
                    media.background(cue: $0, at: model.time,
                                     revision: model.backgroundRevision,
                                     assets: model.document.assets, file: file)
                }
                context.withCGContext { cg in
                    FrameRenderer(assets: SharedAssets.catalog).draw(
                        scene: scene, at: model.time, size: size,
                        background: bg,
                        imageAsset: { media.still(assetID: $0, file: file) },
                        in: cg)
                }
                drawImageCueHighlight(context: context, size: size)
                drawLightHandle(context: context, size: size)
                DispatchQueue.main.async { stageSize = size }
                _ = timeline.date
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.black)
        .gesture(stageDrag)
    }

    /// Dashed outline around the selected image cue while it's on stage.
    private func drawImageCueHighlight(context: GraphicsContext, size: CGSize) {
        guard let path = model.selectedImageCuePath else { return }
        let cue = model.scene.imageTracks[path.track].cues[path.cue]
        guard model.time >= cue.start, model.time < cue.start + cue.dur,
              let img = media.still(assetID: cue.assetID, file: file) else { return }
        let W = Double(size.width), H = Double(size.height)
        let p = cue.placement(at: model.time)
        let w = p.scale * W
        let h = w * Double(img.height) / Double(max(1, img.width))
        let rect = CGRect(x: p.x * W - w / 2, y: p.y * H - h / 2, width: w, height: h)
        context.stroke(Path(roundedRect: rect, cornerRadius: 2),
                       with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
    }

    /// Temporary editor-only handle for the selected light cue: lights never
    /// render in the scene, but while selected they show a draggable point.
    private func drawLightHandle(context: GraphicsContext, size: CGSize) {
        guard let path = model.selectedLightCuePath else { return }
        let cue = model.scene.lightTracks[path.track].cues[path.cue]
        guard model.time >= cue.start, model.time < cue.start + cue.dur else { return }
        let state = cue.state(at: model.time)
        let p = CGPoint(x: state.x * size.width, y: state.y * size.height)
        let r: CGFloat = 10
        context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                       with: .color(.yellow), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                     with: .color(.yellow))
        // Rays hint + intensity readout.
        context.draw(Text(String(format: "☀ %.0f%%", state.intensity * 100))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow),
                     at: CGPoint(x: p.x, y: p.y - r - 8))
    }

    /// Stage drag: repositions the selected image cue if the playhead is inside it
    /// (second half sets the end placement when animated); otherwise moves the
    /// selected character's start pose (web idle drag).
    private var stageDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !model.playing, !model.recording else { return }
                let prev = dragLast ?? .zero
                let dx = (value.translation.width - prev.width) / stageSize.width
                let dy = (value.translation.height - prev.height) / stageSize.height
                dragLast = value.translation

                if let path = model.selectedLightCuePath {
                    var cue = model.scene.lightTracks[path.track].cues[path.cue]
                    if model.time >= cue.start, model.time < cue.start + cue.dur {
                        let inSecondHalf = model.time > cue.start + cue.dur / 2
                        if var end = cue.to, inSecondHalf {
                            end.x = min(1.1, max(-0.1, end.x + dx))
                            end.y = min(1.1, max(-0.1, end.y + dy))
                            cue.to = end
                        } else {
                            cue.from.x = min(1.1, max(-0.1, cue.from.x + dx))
                            cue.from.y = min(1.1, max(-0.1, cue.from.y + dy))
                        }
                        model.scene.lightTracks[path.track].cues[path.cue] = cue
                        return
                    }
                }
                if let path = model.selectedImageCuePath {
                    var cue = model.scene.imageTracks[path.track].cues[path.cue]
                    if model.time >= cue.start, model.time < cue.start + cue.dur {
                        let inSecondHalf = model.time > cue.start + cue.dur / 2
                        if var end = cue.to, inSecondHalf {
                            end.x = min(1.2, max(-0.2, end.x + dx))
                            end.y = min(1.2, max(-0.2, end.y + dy))
                            cue.to = end
                        } else {
                            cue.from.x = min(1.2, max(-0.2, cue.from.x + dx))
                            cue.from.y = min(1.2, max(-0.2, cue.from.y + dy))
                        }
                        model.scene.imageTracks[path.track].cues[path.cue] = cue
                        return
                    }
                }
                guard let i = model.selection.first, model.scene.characters.indices.contains(i) else { return }
                var c = model.scene.characters[i]
                c.x = min(1 - 0.044, max(0.044, c.x + dx))
                c.depth = min(1, max(-12, c.depth - dy * 900 / 120 / (900 / stageSize.height) * 0.016))
                if model.time < 0.1 {
                    c.recStart = StartPose(x: c.x, depth: c.depth, face: c.face)
                }
                model.scene.characters[i] = c
            }
            .onEnded { _ in
                dragLast = nil
                if model.selectedImageCuePath != nil {
                    model.registerUndoSnapshot(label: "Place Image")
                }
            }
    }
}

/// Decodes bank assets for the stage: still images cached, background videos
/// previewed at ~7 fps via throttled async frame generation (export is exact).
@Observable
final class StageMediaCache {
    private var stills: [String: CGImage] = [:]
    private var failed: Set<String> = []
    private var revision = -1
    private var videoGen: [String: (gen: AVAssetImageGenerator, duration: Double)] = [:]
    private var videoFrame: [String: (image: CGImage, t: Double)] = [:]
    private var videoBusy: Set<String> = []

    func still(assetID: String, file: ShowDocumentFile) -> CGImage? {
        if let hit = stills[assetID] { return hit }
        guard !failed.contains(assetID), let mediaData = file.assetsMedia[assetID],
              let src = CGImageSourceCreateWithData(mediaData.data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            failed.insert(assetID)
            return nil
        }
        stills[assetID] = img
        return img
    }

    func background(cue: BackgroundCue, at t: Double, revision: Int,
                    assets: [Asset], file: ShowDocumentFile) -> (image: CGImage, crop: Crop)? {
        if revision != self.revision {
            stills = [:]
            failed = []
            videoGen = [:]
            videoFrame = [:]
            self.revision = revision
        }
        guard let asset = assets.first(where: { $0.id == cue.assetID }) else { return nil }
        switch asset.kind {
        case .image:
            return still(assetID: asset.id, file: file).map { ($0, cue.crop) }
        case .video:
            return videoPreviewFrame(assetID: asset.id, at: t - cue.start, file: file)
                .map { ($0, cue.crop) }
        }
    }

    private func videoPreviewFrame(assetID: String, at t: Double, file: ShowDocumentFile) -> CGImage? {
        guard !failed.contains(assetID) else { return nil }
        if videoGen[assetID] == nil {
            guard let media = file.assetsMedia[assetID] else { failed.insert(assetID); return nil }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bgvid-\(assetID).\(media.ext)")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? media.data.write(to: url)
            }
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1280, height: 720)
            let dur = CMTimeGetSeconds(asset.duration)
            guard dur > 0 else { failed.insert(assetID); return nil }
            videoGen[assetID] = (gen, dur)
        }
        guard let entry = videoGen[assetID] else { return nil }
        let vt = max(0, t).truncatingRemainder(dividingBy: entry.duration)
        let current = videoFrame[assetID]
        if current == nil || abs(current!.t - vt) > 0.15, !videoBusy.contains(assetID) {
            videoBusy.insert(assetID)
            let gen = entry.gen
            Task.detached(priority: .userInitiated) { [weak self] in
                let img = try? gen.copyCGImage(at: CMTime(seconds: vt, preferredTimescale: 600),
                                               actualTime: nil)
                await MainActor.run { [weak self] in
                    if let img { self?.videoFrame[assetID] = (img, vt) }
                    self?.videoBusy.remove(assetID)
                }
            }
        }
        return current?.image
    }
}
