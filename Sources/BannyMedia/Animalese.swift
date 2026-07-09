import Foundation

/// Animal Crossing-style gibberish speech: each letter of the caption becomes
/// a short pitched syllable, so dialogue "reads" without real words. Fully
/// deterministic for a given (text, voice, seed) — regenerating a line always
/// produces the identical clip.
public enum Animalese {

    public struct Voice: Sendable {
        /// Base pitch offset in semitones (-12 low rumble ... +12 chipmunk).
        public var pitch: Double
        /// Speaking rate multiplier (0.6 slow ... 1.6 fast).
        public var speed: Double

        public init(pitch: Double = 0, speed: Double = 1) {
            self.pitch = pitch
            self.speed = speed
        }
    }

    // MARK: - Deterministic RNG

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        /// Uniform in [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }
        /// Uniform in [-1, 1).
        mutating func spread() -> Double { unit() * 2 - 1 }
    }

    // MARK: - Letter voicing tables

    /// Formant targets (F1, F2 in Hz) for vowels; consonants borrow the
    /// nearest vowel color and add a noise onset.
    private static let vowelFormants: [Character: (Double, Double)] = [
        "a": (800, 1200), "e": (500, 1900), "i": (320, 2300),
        "o": (500, 900), "u": (350, 800), "y": (300, 2100),
    ]

    private static let vowels = Set("aeiouy")
    /// Plosives get a sharper, noisier onset than soft consonants.
    private static let plosives = Set("pbtdkgqxcj")

    // MARK: - Render

    /// Renders mono samples at `sampleRate`. When `fitDuration` is set and the
    /// natural length exceeds it, syllables compress to fit (mouth-flap sync:
    /// captions drive the flaps, so the audio must stay inside its caption).
    public static func render(text: String, voice: Voice = Voice(),
                              fitDuration: Double? = nil,
                              sampleRate: Double = 44100,
                              seed: UInt64 = 1) -> [Float] {
        var rng = SplitMix64(state: seed &+ UInt64(abs(text.hashValue)) &* 0x9E3779B9)

        // Segment plan: (kind, letter) — letters speak, gaps rest.
        enum Seg { case letter(Character), gap(Double) }
        var segs: [Seg] = []
        var naturalDur = 0.0
        let letterDur = 0.062 / max(0.3, voice.speed)
        for ch in text.lowercased() {
            if ch.isLetter {
                segs.append(.letter(ch))
                naturalDur += letterDur
            } else if ch.isNumber {
                segs.append(.letter("o"))
                naturalDur += letterDur
            } else if ch == " " {
                segs.append(.gap(letterDur * 0.7)); naturalDur += letterDur * 0.7
            } else if ",.;:!?—-".contains(ch) {
                segs.append(.gap(letterDur * 1.6)); naturalDur += letterDur * 1.6
            }
        }
        guard naturalDur > 0.01 else { return [] }

        // Compress (never stretch) to fit the caption window.
        var timeScale = 1.0
        if let fit = fitDuration, naturalDur > fit, fit > 0.05 {
            timeScale = max(0.45, fit / naturalDur)
        }

        let questioning = text.hasSuffix("?")
        let baseHz = 240.0 * pow(2, voice.pitch / 12)
        let letterCount = max(1, segs.count)

        var out: [Float] = []
        out.reserveCapacity(Int(naturalDur * timeScale * sampleRate) + 64)

        // Two-pole resonator state (simple formant coloring).
        struct Resonator {
            var b1 = 0.0, b2 = 0.0
            mutating func tick(_ x: Double, hz: Double, q: Double, rate: Double) -> Double {
                let w = 2 * Double.pi * hz / rate
                let r = exp(-w / (2 * q))
                let a1 = -2 * r * cos(w)
                let a2 = r * r
                let y = x - a1 * b1 - a2 * b2
                let band = y - b2
                b2 = b1; b1 = y
                return band
            }
        }
        var f1 = Resonator(), f2 = Resonator()
        var phase = 0.0

        for (si, seg) in segs.enumerated() {
            switch seg {
            case .gap(let g):
                out.append(contentsOf: [Float](repeating: 0, count: Int(g * timeScale * sampleRate)))
            case .letter(let ch):
                let dur = letterDur * timeScale * (0.85 + 0.3 * rng.unit())
                let n = max(32, Int(dur * sampleRate))
                let isVowel = vowels.contains(ch)
                let formant = vowelFormants[ch]
                    ?? vowelFormants[["a", "e", "o"][Int(ch.asciiValue ?? 97) % 3]]!

                // Per-letter pitch: hash the letter into a ±4 semitone melody,
                // add sentence contour (falling, or rising when questioning).
                let letterStep = Double((ch.asciiValue ?? 97) % 7) - 3
                let progress = Double(si) / Double(letterCount)
                let contour = questioning ? progress * 4 - 1 : 1 - progress * 3
                let hz = baseHz * pow(2, (letterStep * 0.8 + contour + rng.spread() * 0.4) / 12)

                let noisy = plosives.contains(ch) ? 0.5 : (isVowel ? 0.05 : 0.22)
                let amp = 0.16 * (0.9 + 0.2 * rng.unit())
                let attack = Int(0.006 * sampleRate)
                let release = Int(0.022 * sampleRate)

                for i in 0..<n {
                    // Source: bright sawtooth-ish tone + noise component.
                    phase += hz / sampleRate
                    if phase >= 1 { phase -= 1 }
                    let saw = 2 * phase - 1
                    let noise = rng.spread()
                    let src = saw * (1 - noisy) + noise * noisy
                    // Formant coloring.
                    var y = f1.tick(src, hz: formant.0, q: 6, rate: sampleRate) * 0.7
                    y += f2.tick(src, hz: formant.1, q: 8, rate: sampleRate) * 0.5
                    // Envelope.
                    var env = 1.0
                    if i < attack { env = Double(i) / Double(attack) }
                    let tail = n - i
                    if tail < release { env = min(env, Double(tail) / Double(release)) }
                    out.append(Float(y * env * amp))
                }
            }
        }

        // Normalize to a comfortable peak, soft-limit stray resonances.
        let peak = out.map(abs).max() ?? 1
        if peak > 0 {
            let g = 0.72 / Double(peak)
            for i in out.indices { out[i] = Float(tanh(Double(out[i]) * g * 1.1) / 1.1) }
        }
        return out
    }

    // MARK: - WAV encode (16-bit PCM mono)

    public static func wavData(samples: [Float], sampleRate: Double = 44100) -> Data {
        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: "RIFF".utf8); le32(36 + byteCount)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); le32(16)
        le16(1); le16(1)                          // PCM, mono
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate) * 2)
        le16(2); le16(16)                         // block align, bits
        data.append(contentsOf: "data".utf8); le32(byteCount)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
