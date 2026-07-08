import Foundation
import AVFoundation
import BannyCore

/// Builds the studio's audio graph — the AVAudioEngine port of the web's
/// per-clip `gain → 3-band EQ → pan → track bus (reverb send) → main` chain.
/// One graph type serves realtime playback (app) and offline export (manual
/// rendering mode).
public final class AudioGraph {

    public struct ClipNode {
        public let clip: AudioClip
        /// Which character owns the clip (nil = standalone audio track). Drives pan "follow".
        public let characterIndex: Int?
        let player: AVAudioPlayerNode
        let eq: AVAudioUnitEQ
        let reverb: AVAudioUnitReverb
        let file: AVAudioFile
    }

    public let engine = AVAudioEngine()
    public private(set) var clipNodes: [ClipNode] = []
    /// Track bus mixers keyed by owner: "c<idx>" for characters, track id for audio tracks.
    private var buses: [String: AVAudioMixerNode] = [:]

    public init() {}

    /// Wires every clip in the scene. `audioURL` resolves a clip id to its media file.
    public func build(scene: SceneState, audioURL: (String) -> URL?) throws {
        let main = engine.mainMixerNode

        func bus(for key: String, fx: Fx) -> AVAudioMixerNode {
            if let b = buses[key] { return b }
            let b = AVAudioMixerNode()
            engine.attach(b)
            engine.connect(b, to: main, format: nil)
            b.outputVolume = Float(fx.gain)
            buses[key] = b
            return b
        }

        func wire(_ clip: AudioClip, owner key: String, ownerFx: Fx, characterIndex: Int?) throws {
            guard let url = audioURL(clip.id) else { return }
            let file = try AVAudioFile(forReading: url)
            let player = AVAudioPlayerNode()
            let eq = AVAudioUnitEQ(numberOfBands: 3)
            let reverb = AVAudioUnitReverb()
            for (i, freq) in [320.0, 1000.0, 3200.0].enumerated() {
                let band = eq.bands[i]
                band.filterType = i == 0 ? .lowShelf : i == 2 ? .highShelf : .parametric
                band.frequency = Float(freq)
                band.bandwidth = 1
                band.gain = Float([clip.fx.low, clip.fx.mid, clip.fx.high][i])
                band.bypass = false
            }
            eq.globalGain = 0
            reverb.loadFactoryPreset(.mediumRoom)
            reverb.wetDryMix = Float(clip.fx.reverb * 100)
            engine.attach(player)
            engine.attach(eq)
            engine.attach(reverb)
            // Player feeds a per-clip mixer at the FILE's format; the mixer legally
            // converts (mono mp3 → stereo graph) before the FX chain.
            let clipMixer = AVAudioMixerNode()
            engine.attach(clipMixer)
            let stereo = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            engine.connect(player, to: clipMixer, format: file.processingFormat)
            engine.connect(clipMixer, to: eq, format: stereo)
            engine.connect(eq, to: reverb, format: stereo)
            let busNode = bus(for: key, fx: ownerFx)
            engine.connect(reverb, to: busNode, format: stereo)
            player.volume = Float(clip.fx.gain)
            clipNodes.append(ClipNode(clip: clip, characterIndex: characterIndex,
                                      player: player, eq: eq, reverb: reverb, file: file))
        }

        for (i, c) in scene.characters.enumerated() where !c.hidden {
            for clip in c.clips {
                try wire(clip, owner: "c\(i)", ownerFx: c.trackFx, characterIndex: i)
            }
        }
        for track in scene.audioTracks where !track.hidden {
            for clip in track.clips {
                try wire(clip, owner: track.id, ownerFx: track.fx, characterIndex: nil)
            }
        }
    }

    /// Schedules every clip that intersects [from, ∞) as if the timeline clock starts at `from`.
    /// `at` converts a timeline time to an engine render time (nil = immediately).
    public func schedule(from timelineTime: Double) {
        for node in clipNodes {
            let clip = node.clip
            let clipEnd = clip.start + clip.dur
            guard clipEnd > timelineTime else { continue }

            let intoClip = max(0, timelineTime - clip.start)
            let sourceStart = clip.offset + intoClip
            let remaining = clip.dur - intoClip
            let sampleRate = node.file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(sourceStart * sampleRate)
            let frameCount = AVAudioFrameCount(max(0, min(remaining, clip.srcDur - sourceStart)) * sampleRate)
            guard frameCount > 0, startFrame < node.file.length else { continue }

            let delay = max(0, clip.start - timelineTime)
            let when: AVAudioTime? = delay > 0
                ? AVAudioTime(sampleTime: AVAudioFramePosition(delay * sampleRate), atRate: sampleRate)
                : nil
            node.player.scheduleSegment(node.file, startingFrame: startFrame,
                                        frameCount: min(frameCount, AVAudioFrameCount(node.file.length - startFrame)),
                                        at: when)
        }
    }

    public func playAll() {
        for node in clipNodes { node.player.play() }
    }

    public func stopAll() {
        for node in clipNodes { node.player.stop() }
    }

    /// Web pan modes: follow = character X · 0.3, narrow = 0, wide = X · 2 (clamped).
    public func updatePans(characterX: (Int) -> Double?) {
        for node in clipNodes {
            let pan: Double
            switch node.clip.fx.pan {
            case .value(let v): pan = v
            case .narrow: pan = 0
            case .follow, .wide:
                guard let i = node.characterIndex, let x = characterX(i) else { pan = 0; break }
                let p = x * 2 - 1
                pan = node.clip.fx.pan == .follow ? p * 0.3 : min(1, max(-1, p * 2))
            }
            node.player.pan = Float(pan)
        }
    }
}
