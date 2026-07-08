import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import BannyCore
import BannyRender

/// Offline, deterministic Ship: renders the show playlist (or one whole scene)
/// straight into an H.264 .mp4 — video frames from FrameRenderer at a fixed fps,
/// audio from the same clip graph bounced through AVAudioEngine manual rendering.
/// Faster than realtime; no capture, no dropped frames.
public enum ShowExporter {

    public struct Options: Sendable {
        public var size: CGSize
        public var fps: Int
        public var videoBitrate: Int

        public init(size: CGSize = CGSize(width: 1920, height: 1080), fps: Int = 30,
                    videoBitrate: Int = 12_000_000) {
            self.size = size
            self.fps = fps
            self.videoBitrate = videoBitrate
        }

        public static let p720 = Options(size: CGSize(width: 1280, height: 720), videoBitrate: 8_000_000)
        public static let p1080 = Options()
        public static let p2160 = Options(size: CGSize(width: 3840, height: 2160), videoBitrate: 40_000_000)
    }

    public struct ResolvedSegment {
        public let from: Double
        public let to: Double
    }

    public enum ExportError: Error {
        case nothingToExport
        case writerFailed(String)
    }

    /// Whole-timeline duration when the show playlist is empty.
    public static func contentDuration(of state: SceneState) -> Double {
        max(1, state.contentEnd + 0.5)
    }

    public static func resolveSegments(document: ShowDocument) -> [ResolvedSegment] {
        // The timeline IS the show (the v3 UI removed the segment playlist);
        // legacy `show` entries are ignored so stale segments can't crop a ship.
        [ResolvedSegment(from: 0, to: contentDuration(of: document.stage))]
    }

    /// Renders and writes the mp4. Blocking; call off the main thread.
    /// `assetURL` resolves a bank asset id to its media file (images + videos).
    public static func export(document: ShowDocument,
                              assets: AssetCatalog,
                              audioURL: @escaping (String) -> URL?,
                              assetURL: @escaping (String) -> URL?,
                              options: Options = .p1080,
                              to outputURL: URL,
                              progress: ((Double) -> Void)? = nil) throws {
        let segments = resolveSegments(document: document)
        guard !segments.isEmpty else { throw ExportError.nothingToExport }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let width = Int(options.size.width), height = Int(options.size.height)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(videoInput)

        // Audio: bounce each segment offline up front so the writer interleaves cleanly.
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let audioBuffers = try bounceAudio(document: document, segments: segments,
                                           format: audioFormat, audioURL: audioURL)
        var audioInput: AVAssetWriterInput?
        if !audioBuffers.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        // Audio feed state: AVAssetWriter interleaves non-realtime inputs, so audio
        // must be appended alongside video (a starved input deadlocks the other).
        var audioQueue = audioBuffers
        var audioPos: AVAudioFramePosition = 0
        var audioFinished = false
        func pumpAudio(upTo videoSeconds: Double) {
            guard let audioInput, !audioFinished else { return }
            while let buffer = audioQueue.first,
                  Double(audioPos) / 44100.0 < videoSeconds + 1.0,
                  audioInput.isReadyForMoreMediaData {
                if let sample = makeSampleBuffer(from: buffer, at: audioPos) {
                    audioInput.append(sample)
                }
                audioPos += AVAudioFramePosition(buffer.frameLength)
                audioQueue.removeFirst()
            }
            // Once all audio is in, finish the input so the writer stops waiting
            // for it to interleave and keeps accepting video.
            if audioQueue.isEmpty {
                audioInput.markAsFinished()
                audioFinished = true
            }
        }

        // Video frames.
        let fps = options.fps
        let renderer = FrameRenderer(assets: assets)
        let stage = document.stage
        let bg = BackgroundSampler(assets: document.assets, assetURL: assetURL)
        let stillCache = StillAssetCache(assets: document.assets, assetURL: assetURL)
        let totalFrames = segments.reduce(0) { $0 + Int(((($1.to - $1.from) * Double(fps)).rounded(.up))) }
        var frameIndex = 0
        for segment in segments {
            let segFrames = Int(((segment.to - segment.from) * Double(fps)).rounded(.up))
            for f in 0..<segFrames {
                let t = segment.from + Double(f) / Double(fps)
                guard t < segment.to + 1e-9 else { break }
                autoreleasepool {
                    var pixelBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
                    guard let pb = pixelBuffer else { return }
                    CVPixelBufferLockBaseAddress(pb, [])
                    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                        width: width, height: height,
                                        bitsPerComponent: 8,
                                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)!
                    renderer.draw(scene: stage, at: t, size: options.size,
                                  background: stage.activeBackgroundCue(at: t)
                                      .flatMap { bg.frame(cue: $0, at: t) },
                                  imageAsset: { stillCache.image(for: $0) },
                                  flipped: true, in: ctx)
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    pumpAudio(upTo: Double(frameIndex) / Double(fps))
                    while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
                    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps)))
                    frameIndex += 1
                    progress?(Double(frameIndex) / Double(max(1, totalFrames)) * 0.9)
                }
            }
        }
        videoInput.markAsFinished()

        // Drain any remaining audio.
        if let audioInput, !audioFinished {
            while let buffer = audioQueue.first {
                while !audioInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
                if let sample = makeSampleBuffer(from: buffer, at: audioPos) {
                    audioInput.append(sample)
                }
                audioPos += AVAudioFramePosition(buffer.frameLength)
                audioQueue.removeFirst()
            }
            audioInput.markAsFinished()
        }

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        progress?(1)
    }

    // MARK: - Audio bounce

    /// Renders each segment's audio offline into PCM buffers (concatenated in show order).
    private static func bounceAudio(document: ShowDocument, segments: [ResolvedSegment],
                                    format: AVAudioFormat,
                                    audioURL: (String) -> URL?) throws -> [AVAudioPCMBuffer] {
        var out: [AVAudioPCMBuffer] = []
        let stage = document.stage
        for segment in segments {
            let hasClips = !stage.characters.filter({ !$0.hidden }).flatMap(\.clips).isEmpty
                || !stage.audioTracks.filter({ !$0.hidden }).flatMap(\.clips).isEmpty
            let graph = AudioGraph()
            let duration = segment.to - segment.from
            let frames = AVAudioFrameCount(duration * format.sampleRate)
            guard frames > 0 else { continue }

            try graph.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            if hasClips {
                try graph.build(scene: stage) { audioURL($0) }
            }
            try graph.engine.start()
            if hasClips {
                graph.schedule(from: segment.from)
                // Static pan per segment (follow pans update per-frame only in live playback).
                let sim = SceneSimulator(state: stage)
                graph.updatePans { i in
                    stage.characters.indices.contains(i)
                        ? sim.pose(characterIndex: i, at: segment.from).x : nil
                }
                graph.playAll()
            }

            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            var rendered: AVAudioFrameCount = 0
            let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            while rendered < frames {
                let toRender = min(4096, frames - rendered)
                let status = try graph.engine.renderOffline(toRender, to: chunk)
                guard status == .success else { break }
                // Append chunk into the big buffer.
                for ch in 0..<Int(format.channelCount) {
                    if let dst = buffer.floatChannelData?[ch], let src = chunk.floatChannelData?[ch] {
                        dst.advanced(by: Int(rendered)).update(from: src, count: Int(chunk.frameLength))
                    }
                }
                rendered += chunk.frameLength
                buffer.frameLength = rendered
            }
            graph.engine.stop()
            graph.engine.disableManualRenderingMode()
            out.append(buffer)
        }
        return out
    }

    private static func makeSampleBuffer(from buffer: AVAudioPCMBuffer,
                                         at position: AVAudioFramePosition) -> CMSampleBuffer? {
        let audioBufferList = buffer.mutableAudioBufferList
        var format: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil,
                                       asbd: buffer.format.streamDescription,
                                       layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        guard let format else { return nil }
        var sample: CMSampleBuffer?
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(position), timescale: CMTimeScale(buffer.format.sampleRate)),
            decodeTimeStamp: .invalid)
        var timingCopy = timing
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                             refcon: nil, formatDescription: format,
                             sampleCount: CMItemCount(buffer.frameLength),
                             sampleTimingEntryCount: 1, sampleTimingArray: &timingCopy,
                             sampleSizeEntryCount: 0, sampleSizeArray: nil,
                             sampleBufferOut: &sample)
        guard let sample else { return nil }
        CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil,
                                                       blockBufferMemoryAllocator: nil, flags: 0,
                                                       bufferList: audioBufferList)
        return sample
    }

    /// Bank-asset background source: still images cached; videos sampled
    /// deterministically at (t - cue.start) mod duration (the web bg <video> loops).
    final class BackgroundSampler {
        private let byID: [String: Asset]
        private let assetURL: (String) -> URL?
        private var stills: [String: CGImage] = [:]
        private var videos: [String: (gen: AVAssetImageGenerator, duration: Double)] = [:]

        init(assets: [Asset], assetURL: @escaping (String) -> URL?) {
            self.byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            self.assetURL = assetURL
        }

        func frame(cue: BackgroundCue, at t: Double) -> (image: CGImage, crop: Crop)? {
            guard let asset = byID[cue.assetID], let url = assetURL(cue.assetID) else { return nil }
            switch asset.kind {
            case .image:
                if stills[asset.id] == nil {
                    stills[asset.id] = CGImageSourceCreateWithURL(url as CFURL, nil)
                        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                }
                return stills[asset.id].map { ($0, cue.crop) }
            case .video:
                if videos[asset.id] == nil {
                    let av = AVURLAsset(url: url)
                    let gen = AVAssetImageGenerator(asset: av)
                    gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
                    gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
                    gen.appliesPreferredTrackTransform = true
                    videos[asset.id] = (gen, CMTimeGetSeconds(av.duration))
                }
                guard let v = videos[asset.id], v.duration > 0 else { return nil }
                let vt = (t - cue.start).truncatingRemainder(dividingBy: v.duration)
                guard let img = try? v.gen.copyCGImage(at: CMTime(seconds: max(0, vt), preferredTimescale: 600),
                                                       actualTime: nil) else { return nil }
                return (img, cue.crop)
            }
        }
    }

    /// Still-image bank assets for the image-cue layer.
    final class StillAssetCache {
        private let byID: [String: Asset]
        private let assetURL: (String) -> URL?
        private var cache: [String: CGImage] = [:]

        init(assets: [Asset], assetURL: @escaping (String) -> URL?) {
            self.byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            self.assetURL = assetURL
        }

        func image(for id: String) -> CGImage? {
            if let hit = cache[id] { return hit }
            guard byID[id]?.kind == .image, let url = assetURL(id),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            cache[id] = img
            return img
        }
    }
}
