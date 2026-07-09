import Foundation
import BannyCore
import BannyMedia

/// Animalese caption voicing: every caption on a character becomes a
/// generated gibberish-speech clip at the caption's spot on the timeline.
extension StudioModel {

    /// Regenerates ALL voiced captions for the character (idempotent — prior
    /// generated clips are replaced; imported/recorded clips are untouched).
    @discardableResult
    func generateAnimalese(characterIndex i: Int) -> Int {
        guard scene.characters.indices.contains(i), let file else { return 0 }
        registerUndoSnapshot(label: "Voice Captions")
        var c = scene.characters[i]
        c.clips.removeAll { $0.id.hasPrefix("ani-") }
        let voice = Animalese.Voice(pitch: c.voicePitch, speed: c.voiceSpeed)
        var made = 0
        for (si, sub) in c.subs.enumerated() {
            let text = sub.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let samples = Animalese.render(text: text, voice: voice,
                                           fitDuration: max(0.2, sub.dur),
                                           seed: UInt64(i) &* 1_000_003 &+ UInt64(si))
            guard !samples.isEmpty else { continue }
            let dur = Double(samples.count) / 44100
            let id = "ani-\(ShowDocumentFile.newID())"
            file.audio[id] = (Animalese.wavData(samples: samples), "wav")
            c.clips.append(AudioClip(id: id, name: "v\(si + 1)", start: sub.start,
                                     dur: dur, srcDur: dur))
            made += 1
        }
        c.clips.sort { $0.start < $1.start }
        scene.characters[i] = c
        resyncAudioIfPlaying()
        return made
    }

    /// A short preview line rendered with the character's current profile.
    func animalesePreview(characterIndex i: Int) -> Data? {
        guard let c = scene.characters[safe: i] else { return nil }
        let samples = Animalese.render(
            text: "Well well, banny banana!",
            voice: Animalese.Voice(pitch: c.voicePitch, speed: c.voiceSpeed),
            seed: UInt64(i) &* 1_000_003 &+ 7)
        return samples.isEmpty ? nil : Animalese.wavData(samples: samples)
    }
}
