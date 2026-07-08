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
    @AppStorage("studioLightMode") private var lightMode = false
    @State private var dragLast: CGSize?
    @State private var stageSize: CGSize = .init(width: 1280, height: 720)

    /// The 60fps schedule only runs while something is actually animating;
    /// paused edits redraw via model observation instead.
    private var renderLoopPaused: Bool {
        !model.playing && model.heldCodes.isEmpty && !model.freeformSettling
            && model.heldLightKeys.isEmpty
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: renderLoopPaused)) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                model.tick(now: Date.timeIntervalSinceReferenceDate)
                model.freeformNudge(dt: 1 / 60)
                model.lightTick(dt: 1 / 60)
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
                let bg = scene.activeBackgroundCue(at: model.time).flatMap {
                    media.background(cue: $0, at: model.time, playing: model.playing,
                                     revision: model.backgroundRevision,
                                     assets: model.document.assets, file: file)
                }
                context.withCGContext { cg in
                    FrameRenderer(assets: SharedAssets.catalog).draw(
                        scene: scene, at: model.time, size: size,
                        background: bg,
                        imageAsset: { media.still(assetID: $0, file: file) },
                        poseOverride: !model.playing && model.freeformActive
                            ? { i, pose in model.freeformPose(characterIndex: i, basePose: pose) ?? pose }
                            : nil,
                        in: cg)
                }
                drawImageCueHighlight(context: context, size: size)
                drawLightHandle(context: context, size: size)
                if abs(stageSize.width - size.width) > 1 {
                    DispatchQueue.main.async { stageSize = size }
                }
                _ = timeline.date
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.black)
        .gesture(stageDrag)
    }

    /// Dashed outline around the selected image cue while it's on stage.
    private func drawImageCueHighlight(context: GraphicsContext, size: CGSize) {
        guard let cue = model.selectedImageCueValue else { return }
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
        // While recording image motion, ghost the asset at the pen.
        if model.isImageRecording, let pen = model.imagePenNow {
            let p = CGPoint(x: pen.x * size.width, y: pen.y * size.height)
            if let assetID = model.imageRecordAsset,
               let img = media.still(assetID: assetID, file: file) {
                let w = pen.scale * size.width
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
                let p = CGPoint(x: pen.x * size.width, y: pen.y * size.height)
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
                let p = CGPoint(x: state.x * size.width, y: state.y * size.height)
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
        // Editor-only affordance: never during playback.
        guard !model.playing, let path = model.selectedLightCuePath else { return }
        let cue = model.scene.lightTracks[path.track].cues[path.cue]
        guard model.time >= cue.start, model.time < cue.start + cue.dur else { return }
        let state = cue.state(at: model.time)
        let p = CGPoint(x: state.x * size.width, y: state.y * size.height)
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
                if model.isImageRecording {
                    model.imageRecordSample(x: value.location.x / stageSize.width,
                                            y: value.location.y / stageSize.height)
                    return
                }
                if model.isLightRecording {
                    model.lightRecordSample(x: value.location.x / stageSize.width,
                                            y: value.location.y / stageSize.height)
                    return
                }
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
                c.depth = min(1, max(-12, c.depth - dy * 900 / 120 / (900 / stageSize.height) * 0.016))
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
