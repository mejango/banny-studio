import Foundation
import Testing
@testable import BannyCore

@Test func voiceRecipeFlavorResolvesFromDryToFullStrength() {
    let full = VoiceRecipe.preset(.deepVillain)
    let dry = VoiceRecipe.preset(.deepVillain, flavor: 0).resolved
    let half = VoiceRecipe.preset(.deepVillain, flavor: 0.5).resolved

    #expect(dry.pitchCents == 0)
    #expect(dry.low == 0)
    #expect(dry.distortionMix == 0)
    #expect(abs(half.pitchCents - full.pitchCents * 0.5) < 0.000_1)
    #expect(abs(half.reverbMix - full.reverbMix * 0.5) < 0.000_1)
}

@Test func speechMetadataRoundTripsAndLegacyTTSIsRecognized() throws {
    let profile = SpeechVoiceProfile(
        voiceIdentifier: "voice.example",
        recipe: .preset(.robot, flavor: 0.7),
        automaticMouth: true)
    let clip = AudioClip(
        id: "tts-new",
        name: "Speech",
        start: 2,
        dur: 1,
        srcDur: 1,
        kind: .speech,
        mouthCues: [SpeechMouthCue(start: 0.2, dur: 0.1, shape: .tight)])
    let character = Character(body: .orange, clips: [clip], speechVoice: profile)
    let roundTrip = try JSONDecoder().decode(
        Character.self, from: JSONEncoder().encode(character))

    #expect(roundTrip == character)

    let legacy = try JSONDecoder().decode(AudioClip.self, from: Data(
        #"{"id":"tts-old","name":"Old speech","start":0,"dur":1,"srcDur":1}"#.utf8))
    #expect(legacy.kind == .speech)
    #expect(legacy.mouthCues.isEmpty)

    let partial = try JSONDecoder().decode(Character.self, from: Data(
        #"{"body":"orange","speechVoice":{"recipe":{"preset":"robot"}}}"#.utf8))
    #expect(partial.speechVoice.recipe == .preset(.robot))
    #expect(partial.speechVoice.automaticMouth)
}

@Test func mouthPlannerUsesSampleAnchorsAsBinaryMPressesAndSilence() {
    let cues = SpeechMouthPlanner.cues(
        text: "Bam fish",
        duration: 1.2,
        wordAnchors: [
            SpeechWordAnchor(location: 0, length: 3, time: 0.10),
            SpeechWordAnchor(location: 4, length: 4, time: 0.65),
        ],
        energy: Array(repeating: 0, count: 10)
            + Array(repeating: 1, count: 35)
            + Array(repeating: 0, count: 20)
            + Array(repeating: 1, count: 40)
            + Array(repeating: 0, count: 15),
        energyHop: 0.01)

    #expect(cues.contains { $0.shape == .open })
    #expect(cues.allSatisfy { $0.shape == .open })
    #expect(!cues.contains { $0.start >= 0.45 && $0.start < 0.65 })
    #expect(cues.allSatisfy { $0.start >= 0 && $0.start + $0.dur <= 1.2 })
}

@Test func waveformMouthPlannerTracksRecordedSpeechEnergy() {
    let cues = SpeechMouthPlanner.waveformCues(
        duration: 0.8,
        energy: Array(repeating: 0, count: 10)
            + Array(repeating: 0.2, count: 15)
            + Array(repeating: 0.9, count: 20)
            + Array(repeating: 0, count: 35),
        energyHop: 0.01)
    #expect(cues.contains { $0.shape == .open })
    #expect(cues.allSatisfy { $0.shape == .open })
    #expect(!cues.contains { $0.start < 0.099 })
    #expect(!cues.contains { $0.start >= 0.451 })
}

@Test func speechMouthCuesFollowClipMovesTrimsAndManualOverrides() {
    let clip = AudioClip(
        id: "tts-a",
        name: "Speech",
        start: 10,
        dur: 0.5,
        offset: 0.5,
        srcDur: 2,
        kind: .speech,
        mouthCues: [SpeechMouthCue(start: 0.6, dur: 0.2, shape: .tight)])
    // Legacy tight poses are intentionally normalized to the ordinary M state.
    #expect(clip.mouthShape(at: 10.1) == .open)
    #expect(clip.mouthShape(at: 10.31) == nil)

    let automatic = Character(
        body: .orange,
        clips: [AudioClip(
            id: "tts-b",
            name: "Speech",
            start: 1,
            dur: 1,
            srcDur: 1,
            kind: .speech,
            mouthCues: [SpeechMouthCue(start: 0.2, dur: 0.4, shape: .tight)])])
    let automaticPose = SceneSimulator(
        state: SceneState(characters: [automatic]))
        .pose(characterIndex: 0, at: 1.3)
    #expect(automaticPose.mouthShape == .open)

    var manual = automatic
    manual.events = [
        .key(t: 1.25, code: .keyM, down: true),
        .key(t: 1.35, code: .keyM, down: false),
    ]
    let simulator = SceneSimulator(state: SceneState(characters: [manual]))
    #expect(simulator.pose(characterIndex: 0, at: 1.3).mouthShape == .open)
    #expect(simulator.pose(characterIndex: 0, at: 1.4).mouthShape == .open)

    manual.speechVoice.automaticMouth = false
    #expect(SceneSimulator(state: SceneState(characters: [manual]))
        .pose(characterIndex: 0, at: 1.4).mouthShape == .closed)
}
