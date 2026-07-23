import Foundation
import AVFoundation
#if os(macOS)
import AppKit
#endif
import SwiftUI
import BannyCore

/// Records narration/voice from the microphone straight onto a track as a clip.
/// Start at the playhead; stop registers the take.
@MainActor
@Observable
final class MicRecorder {
    private struct Target {
        let characterIndex: Int?
        let audioTrackIndex: Int?
    }

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var target: Target?
    private var meterTimer: Timer?
    private var startedTransport = false
    private(set) var isRecording = false
    private var startTime: Double = 0
    private(set) var elapsed: Double = 0
    private(set) var level: Double = 0
    private(set) var lastError: String?

    func toggle(model: StudioModel, characterIndex: Int?, audioTrackIndex: Int? = nil) {
        if isRecording {
            stop(model: model)
            return
        }
        guard !model.recording else {
            lastError = "Stop the current performance recording before recording audio."
            return
        }
        if let i = characterIndex, model.scene.characters[safe: i]?.locked == true {
            lastError = "Unlock the character track before recording audio."
            return
        }
        if let i = audioTrackIndex, model.scene.audioTracks[safe: i]?.locked == true {
            lastError = "Unlock the media track before recording audio."
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            start(model: model, target: Target(characterIndex: characterIndex,
                                               audioTrackIndex: audioTrackIndex))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted {
                        self.start(model: model, target: Target(characterIndex: characterIndex,
                                                               audioTrackIndex: audioTrackIndex))
                    } else {
                        self.lastError = "Microphone access was not granted. Enable it in System Settings → Privacy & Security → Microphone."
                    }
                }
            }
        case .denied, .restricted:
            lastError = "Microphone access is off. Enable Banny Studio in System Settings → Privacy & Security → Microphone."
        @unknown default:
            lastError = "The microphone is unavailable."
        }
    }

    func dismissError() {
        lastError = nil
    }

    private func start(model: StudioModel, target: Target) {
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
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else {
            lastError = "Banny Studio could not open the selected microphone."
            return
        }
        rec.isMeteringEnabled = true
        guard rec.prepareToRecord(), rec.record() else {
            lastError = "Banny Studio could not start microphone recording."
            try? FileManager.default.removeItem(at: url)
            return
        }
        self.url = url
        self.target = target
        startTime = model.time
        recorder = rec
        elapsed = 0
        level = 0
        lastError = nil
        isRecording = true
        startedTransport = !model.playing
        if startedTransport { model.play() }
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                self.level = min(1, max(0,
                    (Double(recorder.averagePower(forChannel: 0)) + 60) / 60))
            }
        }
    }

    private func stop(model: StudioModel) {
        guard let rec = recorder, let url, let target else { return }
        let measuredDuration = rec.currentTime
        rec.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        isRecording = false
        if startedTransport, model.playing { model.pause() }
        startedTransport = false
        defer {
            try? FileManager.default.removeItem(at: url)
            self.url = nil
            self.target = nil
            elapsed = 0
            level = 0
            #if os(iOS)
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
        let dur = measuredDuration > 0 ? measuredDuration : (try? AVAudioFile(forReading: url))
            .map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        guard dur > 0.2, let data = try? Data(contentsOf: url) else {
            lastError = "The recording was too short to keep."
            return
        }
        if let index = target.characterIndex {
            guard model.scene.characters[safe: index]?.locked == false else {
                lastError = "The destination character track is no longer available."
                return
            }
        }
        if let index = target.audioTrackIndex {
            guard model.scene.audioTracks[safe: index]?.locked == false else {
                lastError = "The destination media track is no longer available."
                return
            }
        }
        let clipID = model.addRecordedClip(
            data: data,
            ext: "m4a",
            dur: dur,
            startTime: startTime,
            characterIndex: target.characterIndex,
            audioTrackIndex: target.audioTrackIndex)
        if let clipID, let characterIndex = target.characterIndex {
            Task { @MainActor in
                // A microphone take on a character track is presumed dialogue.
                // Failure leaves the audio intact and manual M performance available.
                try? await model.analyzeClipMouth(
                    characterIndex: characterIndex, clipID: clipID)
            }
        }
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
            #if os(macOS)
            if img == nil, let ns = NSImage(data: media.data) {
                var rect = CGRect(x: 0, y: 0, width: max(64, ns.size.width * 2),
                                  height: max(64, ns.size.height * 2))
                img = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            }
            #endif
            let thumbnail = img
            await MainActor.run { [weak self] in
                if let thumbnail {
                    self?.cache[assetID] = thumbnail
                } else {
                    self?.failed.insert(assetID)
                }
                self?.pending.remove(assetID)
            }
        }
        return nil
    }
}
