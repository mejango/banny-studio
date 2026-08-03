import AVFoundation
import XCTest
import BannyCore
@testable import BannyMedia

final class VoiceRecipeAudioGraphTests: XCTestCase {
    func testMuteWinsWhileSoloStillCombinesSelectedTracks() {
        let regular = Character(body: .orange, name: "Regular")
        let muted = Character(body: .orange, name: "Muted", muted: true)
        let soloed = Character(body: .orange, name: "Soloed", solo: true)
        let soloedMedia = AudioTrack(id: "solo-media", name: "Solo Media", solo: true)
        let mutedSolo = AudioTrack(id: "muted-solo", name: "Muted Solo",
                                   muted: true, solo: true)
        let selection = AudioTrackAudibility(scene: SceneState(
            characters: [regular, muted, soloed],
            audioTracks: [soloedMedia, mutedSolo]))

        XCTAssertFalse(selection.includes(regular))
        XCTAssertFalse(selection.includes(muted))
        XCTAssertTrue(selection.includes(soloed))
        XCTAssertTrue(selection.includes(soloedMedia))
        XCTAssertFalse(selection.includes(mutedSolo))
    }

    func testSpeechRecipeIsConfiguredButImportedAudioStaysDry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("banny-voice-graph-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
        buffer.frameLength = 4_410
        try file.write(from: buffer)

        let speech = AudioClip(id: "speech", name: "Speech", start: 0,
                               dur: 0.1, srcDur: 0.1, kind: .speech)
        let imported = AudioClip(id: "imported", name: "Imported", start: 0,
                                 dur: 0.1, srcDur: 0.1)
        let recipe = VoiceRecipe.preset(.robot, flavor: 0.5)
        let character = Character(
            body: .orange,
            clips: [speech, imported],
            speechVoice: SpeechVoiceProfile(recipe: recipe))
        let graph = AudioGraph()
        try graph.build(scene: SceneState(characters: [character]), playbackRate: 2) { _ in url }

        let speechNode = try XCTUnwrap(graph.clipNodes.first { $0.clip.id == "speech" })
        let importedNode = try XCTUnwrap(graph.clipNodes.first { $0.clip.id == "imported" })
        XCTAssertEqual(graph.playbackRate, 2, accuracy: 0.001)
        XCTAssertEqual(speechNode.pitch.rate, 1, accuracy: 0.001,
                       "Transport speed should not overwrite per-voice pitch processing")
        XCTAssertEqual(importedNode.pitch.rate, 1, accuracy: 0.001)
        XCTAssertEqual(speechNode.pitch.pitch, Float(recipe.resolved.pitchCents), accuracy: 0.01)
        XCTAssertGreaterThan(speechNode.distortion.wetDryMix, 0)
        XCTAssertGreaterThan(speechNode.delay.wetDryMix, 0)
        XCTAssertEqual(importedNode.pitch.pitch, 0, accuracy: 0.01)
        XCTAssertEqual(importedNode.distortion.wetDryMix, 0, accuracy: 0.01)
        XCTAssertEqual(importedNode.delay.wetDryMix, 0, accuracy: 0.01)
    }

    func testFutureDialogueIsPrimedWithoutClippingItsHead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("banny-live-dialogue-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        try file.write(from: buffer)

        let dry = AudioClip(id: "dry", name: "Dry dialogue",
                            start: 1, dur: 1, srcDur: 1)
        let faded = AudioClip(id: "faded", name: "Faded dialogue",
                              start: 2, dur: 1, srcDur: 1, fadeIn: 0.1)
        let graph = AudioGraph()
        try graph.build(scene: SceneState(characters: [
            Character(body: .orange, clips: [dry, faded])
        ])) { _ in url }

        graph.updateLevels(timelineTime: 0)

        let dryNode = try XCTUnwrap(graph.clipNodes.first { $0.clip.id == "dry" })
        let fadedNode = try XCTUnwrap(graph.clipNodes.first { $0.clip.id == "faded" })
        XCTAssertEqual(dryNode.mixer.outputVolume, 1, accuracy: 0.001,
                       "A future no-fade clip must already be audible at its scheduled first sample")
        XCTAssertEqual(fadedNode.mixer.outputVolume, 0, accuracy: 0.001,
                       "A deliberate fade-in should still begin silent")
    }
}
