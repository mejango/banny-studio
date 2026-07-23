import AVFoundation
import XCTest
import BannyCore
@testable import BannyMedia

final class VoiceRecipeAudioGraphTests: XCTestCase {
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
        try graph.build(scene: SceneState(characters: [character])) { _ in url }

        let speechNode = try XCTUnwrap(graph.clipNodes.first { $0.clip.id == "speech" })
        let importedNode = try XCTUnwrap(graph.clipNodes.first { $0.clip.id == "imported" })
        XCTAssertEqual(speechNode.pitch.pitch, Float(recipe.resolved.pitchCents), accuracy: 0.01)
        XCTAssertGreaterThan(speechNode.distortion.wetDryMix, 0)
        XCTAssertGreaterThan(speechNode.delay.wetDryMix, 0)
        XCTAssertEqual(importedNode.pitch.pitch, 0, accuracy: 0.01)
        XCTAssertEqual(importedNode.distortion.wetDryMix, 0, accuracy: 0.01)
        XCTAssertEqual(importedNode.delay.wetDryMix, 0, accuracy: 0.01)
    }
}
