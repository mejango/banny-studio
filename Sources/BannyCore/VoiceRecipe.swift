import Foundation

/// Portable, non-destructive processing applied to generated speech.
///
/// Values describe the full-strength sound. `flavor` continuously blends that
/// sound with the unprocessed voice, so one control can make a recipe subtle or
/// theatrical without changing its carefully balanced parameters.
public struct VoiceRecipe: Codable, Equatable, Sendable {
    public enum Preset: String, Codable, CaseIterable, Identifiable, Sendable {
        case natural
        case warmNarrator
        case tinyHero
        case deepVillain
        case radio
        case robot
        case dream
        case ghost
        case alien
        case double
        case arcade
        case custom

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .natural: "Natural"
            case .warmNarrator: "Warm Narrator"
            case .tinyHero: "Tiny Hero"
            case .deepVillain: "Deep Villain"
            case .radio: "Radio"
            case .robot: "Robot"
            case .dream: "Dream"
            case .ghost: "Ghost"
            case .alien: "Alien"
            case .double: "Double"
            case .arcade: "Arcade"
            case .custom: "Custom"
            }
        }

        public var symbol: String {
            switch self {
            case .natural: "waveform"
            case .warmNarrator: "flame"
            case .tinyHero: "sparkles"
            case .deepVillain: "moon.stars"
            case .radio: "radio"
            case .robot: "cpu"
            case .dream: "cloud"
            case .ghost: "wind"
            case .alien: "antenna.radiowaves.left.and.right"
            case .double: "person.2.wave.2"
            case .arcade: "gamecontroller"
            case .custom: "slider.horizontal.3"
            }
        }
    }

    public enum Distortion: String, Codable, CaseIterable, Sendable {
        case none
        case alienChatter
        case cosmicInterference
        case goldenPi
        case radioTower
        case speechWaves
    }

    public enum Space: String, Codable, CaseIterable, Sendable {
        case smallRoom
        case mediumRoom
        case largeRoom
        case mediumHall
        case largeHall
        case plate
        case chamber
        case cathedral
    }

    public var preset: Preset
    public var name: String
    /// Dry at 0, full recipe at 1.
    public var flavor: Double
    /// Pitch shift in cents. Time is preserved.
    public var pitchCents: Double
    /// Three-band tone shaping, in dB.
    public var low: Double
    public var mid: Double
    public var high: Double
    /// Studio compression amount, 0...1.
    public var compression: Double
    public var distortion: Distortion
    public var distortionMix: Double
    public var delayTime: Double
    public var delayFeedback: Double
    public var delayMix: Double
    public var reverbSpace: Space
    public var reverbMix: Double
    /// Short stereo doubling amount, 0...1.
    public var doubling: Double
    /// Final recipe trim in dB.
    public var outputGainDB: Double

    public init(
        preset: Preset = .natural,
        name: String = Preset.natural.displayName,
        flavor: Double = 1,
        pitchCents: Double = 0,
        low: Double = 0,
        mid: Double = 0,
        high: Double = 0,
        compression: Double = 0,
        distortion: Distortion = .none,
        distortionMix: Double = 0,
        delayTime: Double = 0.12,
        delayFeedback: Double = 0,
        delayMix: Double = 0,
        reverbSpace: Space = .mediumRoom,
        reverbMix: Double = 0,
        doubling: Double = 0,
        outputGainDB: Double = 0
    ) {
        self.preset = preset
        self.name = name
        self.flavor = flavor
        self.pitchCents = pitchCents
        self.low = low
        self.mid = mid
        self.high = high
        self.compression = compression
        self.distortion = distortion
        self.distortionMix = distortionMix
        self.delayTime = delayTime
        self.delayFeedback = delayFeedback
        self.delayMix = delayMix
        self.reverbSpace = reverbSpace
        self.reverbMix = reverbMix
        self.doubling = doubling
        self.outputGainDB = outputGainDB
    }

    private enum CodingKeys: String, CodingKey {
        case preset, name, flavor, pitchCents, low, mid, high, compression
        case distortion, distortionMix, delayTime, delayFeedback, delayMix
        case reverbSpace, reverbMix, doubling, outputGainDB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try c.decodeIfPresent(Preset.self, forKey: .preset) ?? .natural
        let defaults = VoiceRecipe.preset(preset)
        self.init(
            preset: preset,
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? defaults.name,
            flavor: try c.decodeIfPresent(Double.self, forKey: .flavor) ?? defaults.flavor,
            pitchCents: try c.decodeIfPresent(Double.self, forKey: .pitchCents)
                ?? defaults.pitchCents,
            low: try c.decodeIfPresent(Double.self, forKey: .low) ?? defaults.low,
            mid: try c.decodeIfPresent(Double.self, forKey: .mid) ?? defaults.mid,
            high: try c.decodeIfPresent(Double.self, forKey: .high) ?? defaults.high,
            compression: try c.decodeIfPresent(Double.self, forKey: .compression)
                ?? defaults.compression,
            distortion: try c.decodeIfPresent(Distortion.self, forKey: .distortion)
                ?? defaults.distortion,
            distortionMix: try c.decodeIfPresent(Double.self, forKey: .distortionMix)
                ?? defaults.distortionMix,
            delayTime: try c.decodeIfPresent(Double.self, forKey: .delayTime)
                ?? defaults.delayTime,
            delayFeedback: try c.decodeIfPresent(Double.self, forKey: .delayFeedback)
                ?? defaults.delayFeedback,
            delayMix: try c.decodeIfPresent(Double.self, forKey: .delayMix)
                ?? defaults.delayMix,
            reverbSpace: try c.decodeIfPresent(Space.self, forKey: .reverbSpace)
                ?? defaults.reverbSpace,
            reverbMix: try c.decodeIfPresent(Double.self, forKey: .reverbMix)
                ?? defaults.reverbMix,
            doubling: try c.decodeIfPresent(Double.self, forKey: .doubling)
                ?? defaults.doubling,
            outputGainDB: try c.decodeIfPresent(Double.self, forKey: .outputGainDB)
                ?? defaults.outputGainDB)
    }

    public static let natural = VoiceRecipe()

    public static let builtIns: [VoiceRecipe] = Preset.allCases
        .filter { $0 != .custom }
        .map { preset($0) }

    public static func preset(_ preset: Preset, flavor: Double = 1) -> VoiceRecipe {
        let recipe: VoiceRecipe
        switch preset {
        case .natural:
            recipe = VoiceRecipe()
        case .warmNarrator:
            recipe = VoiceRecipe(
                preset: preset, name: preset.displayName, pitchCents: -70,
                low: 3.5, mid: 1, high: -1.5, compression: 0.38,
                reverbSpace: .plate, reverbMix: 0.08, outputGainDB: 0.5)
        case .tinyHero:
            recipe = VoiceRecipe(
                preset: preset, name: preset.displayName, pitchCents: 520,
                low: -2.5, mid: 1.5, high: 2.5, compression: 0.42,
                delayTime: 0.026, doubling: 0.12, outputGainDB: -0.5)
        case .deepVillain:
            recipe = VoiceRecipe(
                preset: preset, name: preset.displayName, pitchCents: -430,
                low: 5, mid: -1.5, high: -2, compression: 0.56,
                distortion: .goldenPi, distortionMix: 0.09,
                reverbSpace: .chamber, reverbMix: 0.18, outputGainDB: -1)
        case .radio:
            recipe = VoiceRecipe(
                preset: preset, name: preset.displayName,
                low: -15, mid: 5, high: -13, compression: 0.78,
                distortion: .radioTower, distortionMix: 0.52,
                outputGainDB: -1.5)
        case .robot:
            recipe = VoiceRecipe(
                preset: preset, name: preset.displayName, pitchCents: -60,
                low: -2, mid: 2, high: 1, compression: 0.68,
                distortion: .cosmicInterference, distortionMix: 0.44,
                delayTime: 0.042, delayFeedback: 0.12, delayMix: 0.12,
                outputGainDB: -2)
        case .dream:
            recipe = VoiceRecipe(
                preset: preset, name: preset.displayName, pitchCents: 90,
                low: -1, high: 2, compression: 0.28,
                delayTime: 0.16, delayFeedback: 0.28, delayMix: 0.18,
                reverbSpace: .largeHall, reverbMix: 0.34,
                doubling: 0.24, outputGainDB: -1.5)
        case .ghost:
            recipe = VoiceRecipe(
                preset: preset, name: preset.displayName, pitchCents: -180,
                low: -3, mid: -1, high: 2, compression: 0.32,
                distortion: .speechWaves, distortionMix: 0.10,
                delayTime: 0.22, delayFeedback: 0.40, delayMix: 0.26,
                reverbSpace: .cathedral, reverbMix: 0.45,
                outputGainDB: -2)
        case .alien:
            recipe = VoiceRecipe(
                preset: preset, name: preset.displayName, pitchCents: 310,
                low: -3, mid: 2, high: 2, compression: 0.56,
                distortion: .alienChatter, distortionMix: 0.45,
                delayTime: 0.055, delayFeedback: 0.14, delayMix: 0.13,
                outputGainDB: -2)
        case .double:
            recipe = VoiceRecipe(
                preset: preset, name: preset.displayName, pitchCents: -30,
                low: 1, compression: 0.38, delayTime: 0.026,
                doubling: 0.58, outputGainDB: -1)
        case .arcade:
            recipe = VoiceRecipe(
                preset: preset, name: preset.displayName, pitchCents: 250,
                low: -4, mid: 3, high: 2, compression: 0.58,
                distortion: .speechWaves, distortionMix: 0.34,
                delayTime: 0.075, delayFeedback: 0.18, delayMix: 0.10,
                reverbSpace: .smallRoom, reverbMix: 0.10,
                outputGainDB: -1.5)
        case .custom:
            recipe = VoiceRecipe(preset: .custom, name: Preset.custom.displayName)
        }
        var flavored = recipe
        flavored.flavor = flavor
        return flavored
    }

    /// Parameters after clamping and the global dry-to-flavored interpolation.
    public var resolved: VoiceRecipe {
        let amount = min(1, max(0, flavor.isFinite ? flavor : 1))
        var value = self
        value.flavor = amount
        value.pitchCents = min(2_400, max(-2_400, pitchCents)) * amount
        value.low = min(24, max(-24, low)) * amount
        value.mid = min(24, max(-24, mid)) * amount
        value.high = min(24, max(-24, high)) * amount
        value.compression = min(1, max(0, compression)) * amount
        value.distortionMix = min(1, max(0, distortionMix)) * amount
        value.delayTime = min(0.5, max(0.001, delayTime))
        value.delayFeedback = min(0.8, max(0, delayFeedback)) * amount
        value.delayMix = min(1, max(0, delayMix)) * amount
        value.reverbMix = min(1, max(0, reverbMix)) * amount
        value.doubling = min(1, max(0, doubling)) * amount
        value.outputGainDB = min(12, max(-24, outputGainDB)) * amount
        return value
    }
}

/// The voice and performance behavior owned by one character.
public struct SpeechVoiceProfile: Codable, Equatable, Sendable {
    /// AVSpeechSynthesisVoice identifier. Nil lets the editor choose a local
    /// voice; generated audio remains portable after it is baked into a show.
    public var voiceIdentifier: String?
    public var recipe: VoiceRecipe
    public var automaticMouth: Bool

    public init(voiceIdentifier: String? = nil,
                recipe: VoiceRecipe = .natural,
                automaticMouth: Bool = true) {
        self.voiceIdentifier = voiceIdentifier
        self.recipe = recipe
        self.automaticMouth = automaticMouth
    }

    private enum CodingKeys: String, CodingKey {
        case voiceIdentifier, recipe, automaticMouth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voiceIdentifier = try c.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        recipe = try c.decodeIfPresent(VoiceRecipe.self, forKey: .recipe) ?? .natural
        automaticMouth = try c.decodeIfPresent(Bool.self, forKey: .automaticMouth) ?? true
    }
}

public enum MouthShape: String, Codable, CaseIterable, Sendable {
    case closed
    case tight
    case open
}

/// One source-relative virtual M-key interval baked alongside a speech clip.
/// `shape` remains Codable for older shows, but automatic playback treats every
/// visible cue as the ordinary open-mouth M state.
public struct SpeechMouthCue: Codable, Equatable, Sendable {
    public var start: Double
    public var dur: Double
    public var shape: MouthShape

    public init(start: Double, dur: Double, shape: MouthShape) {
        self.start = max(0, start)
        self.dur = max(0, dur)
        self.shape = shape
    }

    /// Resolves one source-relative cue schedule. Timeline clips and live
    /// previews share this boundary rule so their poses cannot drift apart.
    public static func shape(in cues: [SpeechMouthCue],
                             at sourceTime: Double) -> MouthShape? {
        cues.last {
            sourceTime + 1e-9 >= $0.start
                && sourceTime < $0.start + $0.dur - 1e-9
        }?.shape
    }
}

/// A real timing callback emitted by the speech synthesizer. `location` and
/// `length` are UTF-16 offsets, matching NSString/AVSpeechSynthesizer.
public struct SpeechWordAnchor: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var time: Double

    public init(location: Int, length: Int, time: Double) {
        self.location = location
        self.length = length
        self.time = time
    }
}

/// Deterministic binary mouth automation. Word starts come from the
/// synthesizer's sample clock and the waveform closes the mouth in real
/// silences; every visible interval is otherwise an ordinary M-key press.
public enum SpeechMouthPlanner {
    /// Waveform-only fallback for microphone takes and imported dialogue.
    /// Unlike synthesized speech it cannot know phonemes, but its transitions
    /// are still aligned to the decoded source samples rather than a timer.
    public static func waveformCues(
        duration: Double,
        energy: [Float],
        energyHop: Double
    ) -> [SpeechMouthCue] {
        guard duration.isFinite, duration > 0, !energy.isEmpty else { return [] }
        let hop = min(0.04, max(0.01, energyHop.isFinite ? energyHop : 0.02))
        let levels = normalizedEnergy(energy)
        var bins: [(start: Double, dur: Double, shape: MouthShape)] = []
        var cursor = 0.0
        while cursor < duration {
            let binDuration = min(hop, duration - cursor)
            let level = energyLevel(
                at: cursor + binDuration * 0.5,
                energy: levels,
                hop: energyHop)
            let shape: MouthShape = level <= 0.08 ? .closed : .open
            bins.append((cursor, binDuration, shape))
            cursor += binDuration
        }
        return mergedVisibleCues(bins)
    }

    public static func cues(
        text: String,
        duration: Double,
        wordAnchors: [SpeechWordAnchor],
        energy: [Float],
        energyHop: Double
    ) -> [SpeechMouthCue] {
        guard duration.isFinite, duration > 0 else { return [] }
        let source = text as NSString
        let anchors = wordAnchors
            .filter {
                $0.location >= 0 && $0.length > 0
                    && NSMaxRange(NSRange(location: $0.location, length: $0.length))
                        <= source.length
                    && $0.time.isFinite && $0.time < duration
            }
            .sorted {
                $0.time == $1.time ? $0.location < $1.location : $0.time < $1.time
            }
        guard !anchors.isEmpty else { return [] }

        let hop = min(0.04, max(0.01, energyHop.isFinite ? energyHop : 0.02))
        let levels = normalizedEnergy(energy)
        let voicedThreshold: Float = levels.isEmpty ? -1 : 0.08
        var bins: [(start: Double, dur: Double, shape: MouthShape)] = []
        var anchorIndex = 0
        var cursor = 0.0

        while cursor < duration {
            let binDuration = min(hop, duration - cursor)
            let center = cursor + binDuration * 0.5
            while anchorIndex + 1 < anchors.count,
                  anchors[anchorIndex + 1].time <= center {
                anchorIndex += 1
            }

            let anchor = anchors[anchorIndex]
            let nextStart = anchorIndex + 1 < anchors.count
                ? anchors[anchorIndex + 1].time
                : duration
            let wordStart = max(0, anchor.time - 0.008)
            let wordEnd = max(wordStart + hop, min(duration, nextStart))
            let level = energyLevel(at: center, energy: levels, hop: energyHop)
            let isVoiced = levels.isEmpty || level > voicedThreshold
            let shape: MouthShape =
                center < wordStart || center >= wordEnd || !isVoiced ? .closed : .open
            bins.append((cursor, binDuration, shape))
            cursor += binDuration
        }

        return mergedVisibleCues(bins)
    }

    /// Closed is represented by the gaps between cues. This keeps documents
    /// compact while preserving brief labial closures within a word.
    private static func mergedVisibleCues(
        _ bins: [(start: Double, dur: Double, shape: MouthShape)]
    ) -> [SpeechMouthCue] {
        var result: [SpeechMouthCue] = []
        for bin in bins where bin.shape != .closed {
            if let last = result.last,
               last.shape == bin.shape,
               abs((last.start + last.dur) - bin.start) < 0.000_1 {
                result[result.count - 1].dur += bin.dur
            } else {
                result.append(SpeechMouthCue(
                    start: bin.start, dur: bin.dur, shape: bin.shape))
            }
        }
        return result
    }

    private static func normalizedEnergy(_ input: [Float]) -> [Float] {
        let finite = input.map { $0.isFinite ? max(0, $0) : 0 }
        guard !finite.isEmpty else { return [] }
        let sorted = finite.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let ceiling = sorted[Int(Double(sorted.count - 1) * 0.95)]
        if ceiling - floor < 0.000_001 {
            return ceiling > 0.000_001
                ? finite.map { $0 > ceiling * 0.05 ? 1 : 0 }
                : Array(repeating: 0, count: finite.count)
        }
        let span = ceiling - floor
        return finite.map { min(1, max(0, ($0 - floor) / span)) }
    }

    private static func energyLevel(at time: Double, energy: [Float], hop: Double) -> Float {
        guard !energy.isEmpty, hop.isFinite, hop > 0 else { return 1 }
        let index = min(energy.count - 1, max(0, Int(time / hop)))
        return energy[index]
    }

}
