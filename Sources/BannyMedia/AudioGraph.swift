import Foundation
import AVFoundation
import AudioToolbox
import BannyCore

/// Builds the studio's audio graph — the AVAudioEngine port of the web's
/// per-clip mix plus the speech recipe chain. Generated voices follow
/// `pitch → compression → tone → character → delay/double → space`; imported
/// and microphone clips pass through those recipe stages dry.
/// One graph type serves realtime playback (app) and offline export (manual
/// rendering mode).
public final class AudioGraph {

    public struct ClipNode {
        public let clip: AudioClip
        /// Which character owns the clip (nil = standalone audio track). Drives pan "follow".
        public let characterIndex: Int?
        let player: AVAudioPlayerNode
        let mixer: AVAudioMixerNode
        let pitch: AVAudioUnitTimePitch
        let dynamics: AVAudioUnitEffect
        let eq: AVAudioUnitEQ
        let distortion: AVAudioUnitDistortion
        let delay: AVAudioUnitDelay
        let reverb: AVAudioUnitReverb
        let file: AVAudioFile
    }

    public let engine = AVAudioEngine()
    public private(set) var clipNodes: [ClipNode] = []
    /// Track bus mixers keyed by owner: "c<idx>" for characters, track id for audio tracks.
    private var buses: [String: AVAudioMixerNode] = [:]
    private var masterLimiter: AVAudioUnitEffect?

    public init() {}

    /// Wires every clip in the scene. `audioURL` resolves a clip id to its media file.
    public func build(scene: SceneState, audioURL: (String) -> URL?) throws {
        let main = engine.mainMixerNode
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let master = AVAudioMixerNode()
        let limiter = Self.makePeakLimiter()
        engine.attach(master)
        engine.attach(limiter)
        engine.connect(master, to: limiter, format: stereo)
        engine.connect(limiter, to: main, format: stereo)
        masterLimiter = limiter

        func bus(for key: String, fx: Fx) -> AVAudioMixerNode {
            if let b = buses[key] { return b }
            let b = AVAudioMixerNode()
            engine.attach(b)
            engine.connect(b, to: master, format: stereo)
            b.outputVolume = Float(fx.gain)
            buses[key] = b
            return b
        }

        func wire(_ clip: AudioClip, owner key: String, ownerFx: Fx,
                  characterIndex: Int?, voiceRecipe: VoiceRecipe?) throws {
            guard let url = audioURL(clip.id) else { return }
            let file = try AVAudioFile(forReading: url)
            let player = AVAudioPlayerNode()
            let pitch = AVAudioUnitTimePitch()
            let dynamics = Self.makeDynamicsProcessor()
            let eq = AVAudioUnitEQ(numberOfBands: 3)
            let distortion = AVAudioUnitDistortion()
            let delay = AVAudioUnitDelay()
            let reverb = AVAudioUnitReverb()
            let recipe = (clip.kind == .speech ? voiceRecipe : nil)?.resolved
                ?? VoiceRecipe.natural

            pitch.pitch = Float(recipe.pitchCents)
            pitch.rate = 1
            pitch.overlap = 8
            Self.configureDynamics(dynamics, amount: recipe.compression)
            for (i, freq) in [320.0, 1000.0, 3200.0].enumerated() {
                let band = eq.bands[i]
                band.filterType = i == 0 ? .lowShelf : i == 2 ? .highShelf : .parametric
                band.frequency = Float(freq)
                band.bandwidth = 1
                let recipeGain = [recipe.low, recipe.mid, recipe.high][i]
                band.gain = Float(min(24, max(-24,
                    [clip.fx.low, clip.fx.mid, clip.fx.high][i] + recipeGain)))
                band.bypass = false
            }
            eq.globalGain = 0
            distortion.loadFactoryPreset(Self.distortionPreset(recipe.distortion))
            distortion.wetDryMix = recipe.distortion == .none
                ? 0 : Float(recipe.distortionMix * 100)
            distortion.preGain = -6
            let doubledMix = recipe.doubling * 0.34
            delay.delayTime = recipe.doubling > recipe.delayMix
                ? min(0.035, max(0.014, recipe.delayTime))
                : recipe.delayTime
            delay.feedback = Float(recipe.delayFeedback * 100)
            delay.lowPassCutoff = 12_000
            delay.wetDryMix = Float(min(0.78, recipe.delayMix + doubledMix) * 100)
            reverb.loadFactoryPreset(Self.reverbPreset(recipe.reverbSpace))
            let wet = 1 - (1 - min(1, max(0, clip.fx.reverb)))
                * (1 - recipe.reverbMix)
            reverb.wetDryMix = Float(wet * 100)
            engine.attach(player)
            engine.attach(pitch)
            engine.attach(dynamics)
            engine.attach(eq)
            engine.attach(distortion)
            engine.attach(delay)
            engine.attach(reverb)
            // Player feeds a per-clip mixer at the FILE's format; the mixer legally
            // converts (mono mp3 → stereo graph) before the FX chain.
            let clipMixer = AVAudioMixerNode()
            engine.attach(clipMixer)
            engine.connect(player, to: clipMixer, format: file.processingFormat)
            engine.connect(clipMixer, to: pitch, format: stereo)
            engine.connect(pitch, to: dynamics, format: stereo)
            engine.connect(dynamics, to: eq, format: stereo)
            engine.connect(eq, to: distortion, format: stereo)
            engine.connect(distortion, to: delay, format: stereo)
            engine.connect(delay, to: reverb, format: stereo)
            let busNode = bus(for: key, fx: ownerFx)
            engine.connect(reverb, to: busNode, format: stereo)
            player.volume = Float(clip.fx.gain * pow(10, recipe.outputGainDB / 20))
            clipNodes.append(ClipNode(clip: clip, characterIndex: characterIndex,
                                      player: player, mixer: clipMixer, pitch: pitch,
                                      dynamics: dynamics, eq: eq, distortion: distortion,
                                      delay: delay, reverb: reverb, file: file))
        }

        let hasSolo = scene.characters.contains { !$0.hidden && $0.solo }
            || scene.audioTracks.contains { !$0.hidden && $0.solo }
        for (i, c) in scene.characters.enumerated()
        where !c.hidden && (!hasSolo || c.solo) {
            for clip in c.clips {
                try wire(clip, owner: "c\(i)", ownerFx: c.trackFx,
                         characterIndex: i, voiceRecipe: c.speechVoice.recipe)
            }
        }
        for track in scene.audioTracks where !track.hidden && (!hasSolo || track.solo) {
            for clip in track.clips {
                try wire(clip, owner: track.id, ownerFx: track.fx,
                         characterIndex: nil, voiceRecipe: nil)
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

    /// Applies non-destructive clip fades. Live playback calls this each frame;
    /// offline rendering calls it before every short render chunk.
    public func updateLevels(timelineTime: Double) {
        for node in clipNodes {
            node.mixer.outputVolume = Float(node.clip.level(at: timelineTime))
        }
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

    private static func makeDynamicsProcessor() -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0))
    }

    private static func makePeakLimiter() -> AVAudioUnitEffect {
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0))
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_AttackTime,
                              kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_DecayTime,
                              kAudioUnitScope_Global, 0, 0.05, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain,
                              kAudioUnitScope_Global, 0, 0, 0)
        return limiter
    }

    private static func configureDynamics(_ unit: AVAudioUnitEffect, amount: Double) {
        let value = min(1, max(0, amount))
        unit.bypass = value < 0.001
        guard !unit.bypass else { return }

        func set(_ parameter: AudioUnitParameterID, _ number: Float) {
            AudioUnitSetParameter(unit.audioUnit, parameter, kAudioUnitScope_Global,
                                  0, number, 0)
        }
        set(kDynamicsProcessorParam_Threshold, Float(-8 - value * 18))
        set(kDynamicsProcessorParam_HeadRoom, Float(12 - value * 10))
        set(kDynamicsProcessorParam_ExpansionRatio, 1)
        set(kDynamicsProcessorParam_ExpansionThreshold, -40)
        set(kDynamicsProcessorParam_AttackTime, Float(0.012 - value * 0.009))
        set(kDynamicsProcessorParam_ReleaseTime, Float(0.08 + value * 0.08))
        set(kDynamicsProcessorParam_OverallGain, Float(value * 2.5))
    }

    private static func distortionPreset(
        _ style: VoiceRecipe.Distortion
    ) -> AVAudioUnitDistortionPreset {
        switch style {
        case .none, .speechWaves: .speechWaves
        case .alienChatter: .speechAlienChatter
        case .cosmicInterference: .speechCosmicInterference
        case .goldenPi: .speechGoldenPi
        case .radioTower: .speechRadioTower
        }
    }

    private static func reverbPreset(
        _ space: VoiceRecipe.Space
    ) -> AVAudioUnitReverbPreset {
        switch space {
        case .smallRoom: .smallRoom
        case .mediumRoom: .mediumRoom
        case .largeRoom: .largeRoom
        case .mediumHall: .mediumHall
        case .largeHall: .largeHall
        case .plate: .plate
        case .chamber: .mediumChamber
        case .cathedral: .cathedral
        }
    }
}
