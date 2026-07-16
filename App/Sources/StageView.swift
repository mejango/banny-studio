import SwiftUI
import ImageIO
import AVFoundation
import VideoToolbox
import BannyCore
import BannyRender

/// The live stage: FrameRenderer output driven by the transport clock.
/// Identical draw path to export — what you see is what ships.
struct StageView: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile

    @State private var media = StageMediaCache()
    /// Wall-clock of the previous canvas draw — freeform/pen ticks use REAL
    /// elapsed time, so a slow frame never dilates the animation clock.
    /// (Reference type: mutating it inside the Canvas doesn't re-invalidate.)
    private final class FrameClock { var last: Date? }
    @State private var frameClock = FrameClock()
    @AppStorage("studioLightMode") private var lightMode = false
    @State private var dragLast: CGSize?
    /// Where the frame currently sits inside the canvas (normal: aspect-fit
    /// centered; overview: possibly shrunk). Gestures normalize against it.
    @State private var stageRect = CGRect(x: 0, y: 0, width: 1280, height: 720)

    /// The 60fps schedule only runs while something is actually animating;
    /// paused edits redraw via model observation instead. (No always-on loop
    /// for ambient GIFs — idle must cost nothing; GIFs animate in playback.)
    private var renderLoopPaused: Bool {
        !model.playing && model.heldCodes.isEmpty && !model.freeformSettling
            && model.heldLightKeys.isEmpty
    }

    /// The canvas only spans the full stage box while the overview needs the
    /// wings; everything 60fps (playback, puppeteering, recording) runs on an
    /// aspect-fit canvas — Canvas repaints its whole backing store per tick,
    /// so its size IS the render cost.
    private var overviewLayout: Bool {
        guard !model.playing, !model.recording else { return false }
        let cue = model.selectedBackgroundCueValue
            ?? model.scene.activeBackgroundCue(at: model.time)
        guard let cue, model.time >= cue.start, model.time < cue.start + cue.dur else { return false }
        return true
    }

    var body: some View {
        if overviewLayout {
            stage
        } else {
            stage.aspectRatio(CGFloat(model.frameAspect), contentMode: .fit)
        }
    }

    private var stage: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: renderLoopPaused)) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                model.tick(now: Date.timeIntervalSinceReferenceDate)
                let dt = min(0.1, max(0, timeline.date.timeIntervalSince(frameClock.last ?? timeline.date)))
                frameClock.last = timeline.date
                model.freeformNudge(dt: dt)
                model.lightTick(dt: dt)
                file.audioEngine?.tick(model: model)
                var scene = model.scene
                // Live shadows while drawing a light: the pen stands in for
                // the track's cues so position/intensity/size show immediately.
                if let li = model.lightRecordTrack, let pen = model.lightPenNow,
                   scene.lightTracks.indices.contains(li) {
                    scene.lightTracks[li].cues = [LightCue(
                        id: "live-pen", start: 0, dur: .greatestFiniteMagnitude,
                        from: LightState(x: pen.x, y: pen.y,
                                         intensity: pen.intensity, size: pen.size))]
                }
                // Live camera while recording — or the paused freeform pen —
                // stands in for the cues.
                let liveCam: CameraState? = model.isCameraRecording
                    ? model.cameraPenNow.map { CameraState(x: $0.x, y: $0.y, zoom: $0.zoom) }
                    : (!model.playing ? model.cameraFreeform : nil)
                if let liveCam {
                    for ti in scene.backgroundTracks.indices {
                        for ci in scene.backgroundTracks[ti].cues.indices {
                            scene.backgroundTracks[ti].cues[ci].camFrom = liveCam
                            scene.backgroundTracks[ti].cues[ci].camTo = nil
                        }
                    }
                }
                let bg = scene.activeBackgroundCue(at: model.time).flatMap {
                    media.background(cue: $0, at: model.time, playing: model.playing,
                                     revision: model.backgroundRevision,
                                     assets: model.document.assets, file: file)
                }
                // Frame layout: aspect-fit, centered, ALWAYS full height/width of
                // its fit box; the overview only shrinks when the background
                // overflow can't fit the canvas's spare (letterbox) space.
                let aspect = CGFloat(model.frameAspect)
                let fw = min(size.width, size.height * aspect)
                let frameSize = CGSize(width: fw, height: fw / aspect)
                let shrink = overviewShrink(frameSize: frameSize, canvas: size)
                let s = shrink ?? 1
                let rect = CGRect(x: size.width / 2 - frameSize.width * s / 2,
                                  y: size.height / 2 - frameSize.height * s / 2,
                                  width: frameSize.width * s,
                                  height: frameSize.height * s)
                let poseOverride: ((Int, CharacterPose) -> CharacterPose)? =
                    !model.playing && model.freeformActive
                        ? { i, pose in model.freeformPose(characterIndex: i, basePose: pose) ?? pose }
                        : nil
                let render: (SceneState, CGContext) -> Void = { drawScene, cg in
                    cg.saveGState()
                    cg.translateBy(x: rect.minX, y: rect.minY)
                    cg.scaleBy(x: s, y: s)
                    FrameRenderer(assets: SharedAssets.catalog).draw(
                        scene: drawScene, at: model.time, size: frameSize,
                        background: bg,
                        imageAsset: { media.still(assetID: $0, file: file) },
                        poseOverride: poseOverride,
                        in: cg)
                    cg.restoreGState()
                }
                if shrink != nil {
                    // Wings pass: the world with NO camera, at a fixed scale —
                    // zooming never grows the background. Everything dims.
                    var wingsScene = scene
                    for ti in wingsScene.backgroundTracks.indices {
                        for ci in wingsScene.backgroundTracks[ti].cues.indices {
                            wingsScene.backgroundTracks[ti].cues[ci].camFrom = nil
                            wingsScene.backgroundTracks[ti].cues[ci].camTo = nil
                        }
                    }
                    context.withCGContext { cg in render(wingsScene, cg) }
                    context.fill(Path(CGRect(origin: .zero, size: size)),
                                 with: .color(.black.opacity(0.5)))
                    // Dashed viewfinder: where the camera cuts the background.
                    if let bg, var cam = scene.activeBackgroundCue(at: model.time)?
                        .camera(at: model.time) {
                        let r0 = FrameRenderer.backgroundRect(
                            imageWidth: bg.image.width, imageHeight: bg.image.height,
                            crop: bg.crop, size: frameSize)
                        cam = FrameRenderer.clampCamera(cam, background: r0, size: frameSize)
                        if cam != CameraState() {
                            let z = CGFloat(max(0.1, cam.zoom))
                            let cut = CGRect(
                                x: rect.minX + s * (CGFloat(cam.x) * frameSize.width - frameSize.width / (2 * z)),
                                y: rect.minY + s * (CGFloat(cam.y) * frameSize.height - frameSize.height / (2 * z)),
                                width: s * frameSize.width / z,
                                height: s * frameSize.height / z)
                            context.stroke(Path(cut), with: .color(.white.opacity(0.8)),
                                           style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        }
                    }
                    // Frame pass: the shipped view, fixed size, bright, on top.
                    context.withCGContext { cg in
                        cg.saveGState()
                        cg.clip(to: rect)
                        render(scene, cg)
                        cg.restoreGState()
                    }
                    context.stroke(Path(rect), with: .color(.white.opacity(0.9)),
                                   lineWidth: 1.5)
                } else {
                    context.withCGContext { cg in
                        cg.saveGState()
                        cg.clip(to: rect) // normal view: the world clips at the frame
                        render(scene, cg)
                        cg.restoreGState()
                    }
                }
                drawImageCueHighlight(context: context, rect: rect)
                drawLightHandle(context: context, rect: rect)
                if abs(stageRect.minX - rect.minX) > 0.5 || abs(stageRect.minY - rect.minY) > 0.5
                    || abs(stageRect.width - rect.width) > 0.5 {
                    DispatchQueue.main.async { stageRect = rect }
                }
                _ = timeline.date
            }
        }
        .background(Color.black)
        .gesture(stageDrag)
    }

    /// Frame overview while a scene cue is selected (paused): the whole
    /// background becomes visible around the frame. Returns the frame scale —
    /// 1 when the overflow fits the canvas's spare space (frame keeps its full
    /// size), smaller only when it must shrink to fit. Nil = no overview.
    private func overviewShrink(frameSize: CGSize, canvas: CGSize) -> CGFloat? {
        // Overview is for ARRANGING and puppeteering — the wings stay up while
        // paused; playback and recording show the clean framed view.
        guard !model.playing, !model.recording else { return nil }
        // Any paused edit shows the wings: the selected scene cue, else the
        // one under the playhead — useful for staging things outside the
        // frame that enter it later.
        let cue = model.selectedBackgroundCueValue
            ?? model.scene.activeBackgroundCue(at: model.time)
        guard let cue,
              model.time >= cue.start, model.time < cue.start + cue.dur,
              let bg = media.background(cue: cue, at: model.time, playing: false,
                                        revision: model.backgroundRevision,
                                        assets: model.document.assets, file: file)
        else { return nil }
        let W = frameSize.width, H = frameSize.height
        // The wings render with NO camera, so the fit ignores zoom — the
        // ensemble never grows or shifts while the camera moves.
        let r = FrameRenderer.backgroundRect(imageWidth: bg.image.width,
                                             imageHeight: bg.image.height,
                                             crop: bg.crop, size: frameSize)
        let union = r.union(CGRect(x: 0, y: 0, width: W, height: H))
        // Nothing beyond the frame → normal view.
        guard union.width > W + 1 || union.height > H + 1 else { return nil }
        // The frame's center stays at the canvas center; shrink only as far as
        // the overflow demands.
        let maxX = max(union.maxX - W / 2, W / 2 - union.minX)
        let maxY = max(union.maxY - H / 2, H / 2 - union.minY)
        return min(1, 0.99 * min(canvas.width / 2 / maxX, canvas.height / 2 / maxY))
    }

    /// Dashed outline around the selected image cue while it's on stage.
    private func drawImageCueHighlight(context: GraphicsContext, rect frame: CGRect) {
        guard let cue = model.selectedImageCueValue else { return }
        guard model.time >= cue.start, model.time < cue.start + cue.dur,
              let img = media.still(assetID: cue.assetID, file: file) else { return }
        let W = Double(frame.width), H = Double(frame.height)
        let p = cue.placement(at: model.time)
        let w = p.scale * W
        let h = w * Double(img.height) / Double(max(1, img.width))
        let rect = CGRect(x: frame.minX + p.x * W - w / 2, y: frame.minY + p.y * H - h / 2,
                          width: w, height: h)
        context.stroke(Path(roundedRect: rect, cornerRadius: 2),
                       with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
    }

    /// Temporary editor-only handle for the selected light cue: lights never
    /// render in the scene, but while selected they show a draggable point.
    private func drawLightHandle(context: GraphicsContext, rect frame: CGRect) {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
        }
        // While recording image motion, ghost the asset at the pen.
        if model.isImageRecording, let pen = model.imagePenNow {
            let p = point(pen.x, pen.y)
            if let assetID = model.imageRecordAsset,
               let img = media.still(assetID: assetID, file: file) {
                let w = pen.scale * frame.width
                let h = w * CGFloat(img.height) / CGFloat(max(1, img.width))
                var ghost = context
                ghost.opacity = 0.75
                ghost.draw(Image(decorative: img, scale: 1).interpolation(.none),
                           in: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h))
                context.stroke(Path(roundedRect: CGRect(x: p.x - w / 2, y: p.y - h / 2,
                                                        width: w, height: h), cornerRadius: 2),
                               with: .color(.red), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            } else {
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                               with: .color(.red), lineWidth: 1.5)
            }
            return
        }
        // While drawing a light path, show the pen position.
        if model.isLightRecording {
            if let pen = model.lightPenNow {
                let p = point(pen.x, pen.y)
                let r = max(6, min(24, 10 * pen.size / 120))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                             with: .color(.black))
                context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                               with: .color(.red), lineWidth: 1.5)
                context.draw(Text(String(format: "☀ %.0f%%", pen.intensity * 100))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black),
                             at: CGPoint(x: p.x, y: p.y - r - 8))
            }
            return
        }
        // A selected light TRACK always shows where its light is right now.
        if model.selectedLightCuePath == nil,
           let key = model.selectedTrackKey,
           let track = model.scene.lightTracks.first(where: { $0.id == key }),
           !track.hidden, track.presence.isPresent(at: model.time) {
            // Only while a cue is actually shining — no ghost ring after the
            // light's stream ends.
            let state = track.cues.first { model.time >= $0.start && model.time < $0.start + $0.dur }?
                .state(at: model.time)
            if let state {
                let p = point(state.x, state.y)
                let r = max(6, min(24, 10 * state.size / 120))
                context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                               with: .color(.black), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                             with: .color(.black))
                context.draw(Text(String(format: "☀ %.0f%%", state.intensity * 100))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black),
                             at: CGPoint(x: p.x, y: p.y - r - 8))
            }
            return
        }
        // Editor-only affordance: never during playback, and only while the
        // cue's own light track is the selected track.
        guard !model.playing, let path = model.selectedLightCuePath,
              model.selectedTrackKey == model.scene.lightTracks[path.track].id else { return }
        let cue = model.scene.lightTracks[path.track].cues[path.cue]
        guard model.time >= cue.start, model.time < cue.start + cue.dur else { return }
        let state = cue.state(at: model.time)
        let p = point(state.x, state.y)
        let r = max(6, min(24, 10 * state.size / 120))
        context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                       with: .color(.black), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                     with: .color(.black))
        // Rays hint + intensity readout.
        context.draw(Text(String(format: "☀ %.0f%%", state.intensity * 100))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black),
                     at: CGPoint(x: p.x, y: p.y - r - 8))
    }

    /// Stage drag: repositions the selected image cue if the playhead is inside it
    /// (second half sets the end placement when animated); otherwise moves the
    /// selected character's start pose (web idle drag).
    private var stageDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let fx = (value.location.x - stageRect.minX) / stageRect.width
                let fy = (value.location.y - stageRect.minY) / stageRect.height
                if model.isImageRecording {
                    model.imageRecordSample(x: fx, y: fy)
                    return
                }
                if model.isCameraRecording {
                    model.cameraRecordSample(x: fx, y: fy)
                    return
                }
                if model.isLightRecording {
                    model.lightRecordSample(x: fx, y: fy)
                    return
                }
                guard !model.playing, !model.recording else { return }
                let prev = dragLast ?? .zero
                let dx = (value.translation.width - prev.width) / stageRect.width
                let dy = (value.translation.height - prev.height) / stageRect.height
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
                // Frame pan: grab-the-world drag while the Scenes track is
                // selected — moves the freeform pen; commit with the Scenes
                // row's "Set start position".
                if let key = model.selectedTrackKey,
                   model.scene.backgroundTracks.contains(where: { $0.id == key }) {
                    model.cameraFreeformDrag(dx: dx, dy: dy)
                    return
                }
                if let cue = model.selectedImageCueValue,
                   model.time >= cue.start, model.time < cue.start + cue.dur {
                    let inSecondHalf = model.time > cue.start + cue.dur / 2
                    model.updateSelectedImageCue { cue in
                        if var end = cue.to, inSecondHalf {
                            end.x = min(1.2, max(-0.2, end.x + dx))
                            end.y = min(1.2, max(-0.2, end.y + dy))
                            cue.to = end
                        } else {
                            cue.from.x = min(1.2, max(-0.2, cue.from.x + dx))
                            cue.from.y = min(1.2, max(-0.2, cue.from.y + dy))
                        }
                    }
                    return
                }
                guard let i = model.selection.first, model.scene.characters.indices.contains(i) else { return }
                var c = model.scene.characters[i]
                c.x = min(1 - 0.044, max(0.044, c.x + dx))
                c.depth = min(1, max(-12, c.depth - dy * 900 / 120 / (900 / stageRect.height) * 0.016))
                if model.time < 0.1 {
                    c.recStart = StartPose(x: c.x, depth: c.depth, face: c.face)
                }
                model.scene.characters[i] = c
            }
            .onEnded { _ in
                dragLast = nil
                if model.selectedImageCueValue != nil {
                    model.registerUndoSnapshot(label: "Place Image")
                }
            }
    }
}

/// Decodes bank assets for the stage. Stills are cached. Background videos use
/// two paths: while PLAYING, a muted AVPlayer + AVPlayerItemVideoOutput streams
/// hardware-decoded frames at full rate (kept within 0.3s of the show clock);
/// while paused/scrubbing, an AVAssetImageGenerator seeks the exact frame.
/// Export never uses either — it samples deterministically.
@Observable
final class StageMediaCache {
    private var stills: [String: CGImage] = [:]
    private var gifs: [String: GifSequence] = [:]
    private var notAnimated: Set<String> = []
    private var failed: Set<String> = []
    private var revision = -1
    private var videoGen: [String: (gen: AVAssetImageGenerator, duration: Double)] = [:]
    private var videoFrame: [String: (image: CGImage, t: Double)] = [:]
    private var videoBusy: Set<String> = []
    @ObservationIgnored private var players: [String: (player: AVPlayer, output: AVPlayerItemVideoOutput, duration: Double)] = [:]
    @ObservationIgnored private var playbackFrame: [String: CGImage] = [:]

    func still(assetID: String, file: ShowDocumentFile) -> CGImage? {
        if let hit = stills[assetID] { return hit }
        guard !failed.contains(assetID), let mediaData = file.assetsMedia[assetID] else {
            failed.insert(assetID)
            return nil
        }
        var img = CGImageSourceCreateWithData(mediaData.data as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        #if os(macOS)
        if img == nil, let ns = NSImage(data: mediaData.data) {
            // SVG (and anything else ImageIO can't touch) rasterizes via NSImage.
            var rect = CGRect(x: 0, y: 0, width: max(64, ns.size.width * 2),
                              height: max(64, ns.size.height * 2))
            img = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        #endif
        guard let img else {
            failed.insert(assetID)
            return nil
        }
        stills[assetID] = img
        return img
    }

    func background(cue: BackgroundCue, at t: Double, playing: Bool, revision: Int,
                    assets: [Asset], file: ShowDocumentFile) -> (image: CGImage, crop: Crop)? {
        if revision != self.revision {
            stills = [:]
            gifs = [:]
            notAnimated = []
            failed = []
            videoGen = [:]
            videoFrame = [:]
            for entry in players.values { entry.player.pause() }
            players = [:]
            playbackFrame = [:]
            self.revision = revision
        }
        guard let asset = assets.first(where: { $0.id == cue.assetID }) else { return nil }
        switch asset.kind {
        case .image:
            // Animated GIFs play by the show clock (loops; matches export).
            if let seq = gif(assetID: asset.id, file: file) {
                return (seq.frame(at: max(0, t - cue.start)), cue.crop)
            }
            return still(assetID: asset.id, file: file).map { ($0, cue.crop) }
        case .video:
            if playing, let img = playerFrame(assetID: asset.id, at: t - cue.start, file: file) {
                return (img, cue.crop)
            }
            if !playing {
                for entry in players.values where entry.player.rate != 0 { entry.player.pause() }
            }
            return videoPreviewFrame(assetID: asset.id, at: t - cue.start, file: file)
                .map { ($0, cue.crop) }
        }
    }

    private func gif(assetID: String, file: ShowDocumentFile) -> GifSequence? {
        if let hit = gifs[assetID] { return hit }
        guard !notAnimated.contains(assetID) else { return nil }
        if let media = file.assetsMedia[assetID], let seq = GifSequence(data: media.data) {
            gifs[assetID] = seq
            return seq
        }
        notAnimated.insert(assetID)
        return nil
    }

    /// Streaming path while the transport runs: a muted AVPlayer decodes in
    /// hardware and we pull whatever frame is current each render tick.
    private func playerFrame(assetID: String, at t: Double, file: ShowDocumentFile) -> CGImage? {
        if players[assetID] == nil {
            guard !failed.contains(assetID), let url = mediaURL(assetID: assetID, file: file) else { return nil }
            let asset = AVURLAsset(url: url)
            let dur = CMTimeGetSeconds(asset.duration)
            guard dur > 0 else { return nil }
            let item = AVPlayerItem(asset: asset)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .none // looping = the drift check seeks back
            players[assetID] = (player, output, dur)
        }
        guard let p = players[assetID] else { return nil }
        let vt = max(0, t).truncatingRemainder(dividingBy: p.duration)
        if p.player.rate == 0 { p.player.play() }
        // Keep the player within 0.3s of the show clock (also handles the loop wrap).
        if abs(p.player.currentTime().seconds - vt) > 0.3 {
            p.player.seek(to: CMTime(seconds: vt, preferredTimescale: 600),
                          toleranceBefore: CMTime(value: 1, timescale: 10),
                          toleranceAfter: CMTime(value: 1, timescale: 10))
        }
        let itemTime = p.output.itemTime(forHostTime: CACurrentMediaTime())
        if p.output.hasNewPixelBuffer(forItemTime: itemTime),
           let buf = p.output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            var img: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buf, options: nil, imageOut: &img)
            if let img { playbackFrame[assetID] = img }
        }
        // Until the first buffer lands, fall through to the generator's frame.
        return playbackFrame[assetID] ?? videoFrame[assetID]?.image
    }

    private func mediaURL(assetID: String, file: ShowDocumentFile) -> URL? {
        guard let media = file.assetsMedia[assetID] else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgvid-\(assetID).\(media.ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? media.data.write(to: url)
        }
        return url
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
        if current == nil || abs(current!.t - vt) > 0.07, !videoBusy.contains(assetID) {
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
