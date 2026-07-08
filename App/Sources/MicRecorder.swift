import Foundation
import AVFoundation
import SwiftUI
import BannyCore

/// Records narration/voice from the microphone straight onto a track as a clip.
/// Start at the playhead; stop registers the take.
@MainActor
@Observable
final class MicRecorder {
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private(set) var isRecording = false
    private var startTime: Double = 0

    func toggle(model: StudioModel, characterIndex: Int?) {
        if isRecording { stop(model: model, characterIndex: characterIndex) } else { start(model: model) }
    }

    private func start(model: StudioModel) {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("take-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return }
        self.url = url
        startTime = model.time
        rec.record()
        recorder = rec
        isRecording = true
    }

    private func stop(model: StudioModel, characterIndex: Int?) {
        guard let rec = recorder, let url else { return }
        rec.stop()
        recorder = nil
        isRecording = false
        let dur = rec.currentTime > 0 ? rec.currentTime : (try? AVAudioFile(forReading: url))
            .map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        guard dur > 0.2, let data = try? Data(contentsOf: url) else { return }
        model.addRecordedClip(data: data, ext: "m4a", dur: dur,
                              startTime: startTime, characterIndex: characterIndex)
    }
}

/// Decodes and caches waveform peaks per clip for timeline drawing.
@Observable
final class PeakCache {
    /// clipId → normalized peaks 0..1 (fixed bucket count over the SOURCE file).
    private(set) var peaks: [String: [Float]] = [:]
    private var pending: Set<String> = []
    static let buckets = 400

    func peaks(for clipID: String, file: ShowDocumentFile) -> [Float]? {
        if let p = peaks[clipID] { return p }
        guard !pending.contains(clipID), let media = file.audio[clipID] else { return nil }
        pending.insert(clipID)
        Task.detached(priority: .utility) { [weak self] in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("peaks-\(clipID).\(media.ext)")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? media.data.write(to: url)
            }
            let decoded = Self.decodePeaks(url: url)
            await MainActor.run { [weak self] in
                self?.peaks[clipID] = decoded ?? []
                self?.pending.remove(clipID)
            }
        }
        return nil
    }

    private static func decodePeaks(url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        guard total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength)
        let bucketSize = max(1, n / buckets)
        var out: [Float] = []
        out.reserveCapacity(buckets)
        var i = 0
        while i < n {
            var peak: Float = 0
            let end = min(n, i + bucketSize)
            while i < end {
                peak = max(peak, abs(data[i]))
                i += 1
            }
            out.append(min(1, peak))
        }
        return out
    }
}

/// Small tiled thumbnails for timeline cue bars (video assets get a poster frame).
@Observable
final class CueThumbCache {
    private var cache: [String: CGImage] = [:]
    private var pending: Set<String> = []
    private var failed: Set<String> = []

    func thumb(assetID: String, file: ShowDocumentFile?) -> CGImage? {
        if let hit = cache[assetID] { return hit }
        guard let file, !failed.contains(assetID), !pending.contains(assetID),
              let media = file.assetsMedia[assetID] else { return nil }
        pending.insert(assetID)
        let isVideo = ["mp4", "mov", "webm", "m4v"].contains(media.ext)
        Task.detached(priority: .utility) { [weak self] in
            var img: CGImage?
            if isVideo {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cuethumb-\(assetID).\(media.ext)")
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? media.data.write(to: url)
                }
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 512, height: 512)
                img = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
            } else if let src = CGImageSourceCreateWithData(media.data as CFData, nil) {
                img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                ] as CFDictionary)
            }
            await MainActor.run { [weak self] in
                if let img { self?.cache[assetID] = img } else { self?.failed.insert(assetID) }
                self?.pending.remove(assetID)
            }
        }
        return nil
    }
}
