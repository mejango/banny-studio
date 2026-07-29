import Testing
@testable import BannyCore

@Test func keepRangeTrimsClipBasedContentWithoutTouchingPerformance() {
    let performance: [PerfEvent] = [
        .key(t: 1, code: .arrowRight, down: true),
        .key(t: 9, code: .arrowRight, down: false),
    ]
    let image = ImageCue(
        id: "image", assetID: "asset", start: 0, dur: 10,
        from: ImagePlacement(x: 0, y: 0, scale: 0.2),
        to: ImagePlacement(x: 1, y: 1, scale: 0.4),
        playback: MediaPlayback(rate: 2))
    var scene = SceneState(
        characters: [Character(
            body: .orange,
            subs: [Subtitle(text: "line", start: 2, dur: 6)],
            clips: [AudioClip(id: "speech", name: "Speech", start: 0, dur: 10,
                              offset: 1, srcDur: 20, fadeIn: 1, fadeOut: 1)],
            events: performance)],
        imageTracks: [ImageTrack(id: "images", name: "Images", cues: [image])],
        backgroundTracks: [BackgroundTrack(
            id: "scenes", name: "Scenes",
            cues: [BackgroundCue(
                id: "scene", assetID: "set", start: 0, dur: 10,
                camFrom: CameraState(x: 0, y: 0, zoom: 1),
                camTo: CameraState(x: 1, y: 1, zoom: 3))])],
        lightTracks: [LightTrack(
            id: "lights", name: "Lights",
            cues: [LightCue(
                id: "light", start: 0, dur: 10,
                from: LightState(x: 0, y: 0, intensity: 0, size: 100),
                to: LightState(x: 1, y: 1, intensity: 1, size: 200))])])

    let result = TimelineRangeEditor.apply(
        .keep, from: 3, to: 7,
        targets: [.character(0), .image(0), .background(0), .light(0)],
        scene: &scene,
        makeID: { "unused" })

    #expect(result.changed)
    #expect(result.audioClones.isEmpty)
    #expect(scene.characters[0].events == performance)
    #expect(scene.characters[0].clips[0].start == 3)
    #expect(scene.characters[0].clips[0].dur == 4)
    #expect(scene.characters[0].clips[0].offset == 4)
    #expect(scene.characters[0].clips[0].fadeIn == 0)
    #expect(scene.characters[0].clips[0].fadeOut == 0)
    #expect(scene.characters[0].subs == [Subtitle(text: "line", start: 3, dur: 4)])

    let keptImage = scene.imageTracks[0].cues[0]
    #expect(keptImage.start == 3 && keptImage.dur == 4)
    #expect(abs(keptImage.from.x - 0.3) < 1e-9)
    #expect(abs(keptImage.to!.x - 0.7) < 1e-9)
    #expect(keptImage.playback.phaseOffset == 6)

    let keptLight = scene.lightTracks[0].cues[0]
    #expect(abs(keptLight.from.intensity - 0.3) < 1e-9)
    #expect(abs(keptLight.to!.intensity - 0.7) < 1e-9)

    let keptScene = scene.backgroundTracks[0].cues[0]
    #expect(abs(keptScene.camFrom!.x - 0.3) < 1e-9)
    #expect(abs(keptScene.camTo!.x - 0.7) < 1e-9)
}

@Test func removeRangeSplitsSpanningMediaAndReportsAudioClone() {
    let cue = ImageCue(
        id: "visual", assetID: "asset", start: 0, dur: 10,
        from: ImagePlacement(x: 0, y: 0, scale: 0.2),
        to: ImagePlacement(x: 1, y: 1, scale: 0.4))
    var scene = SceneState(
        audioTracks: [AudioTrack(
            id: "media", name: "Media",
            clips: [AudioClip(id: "audio", name: "Audio", start: 0, dur: 10,
                              offset: 2, srcDur: 20, fadeIn: 1, fadeOut: 1)],
            cues: [cue])],
        imageTracks: [ImageTrack(
            id: "locked", name: "Locked", locked: true, cues: [cue])])
    var id = 0
    let result = TimelineRangeEditor.apply(
        .remove, from: 3, to: 7,
        targets: [.audio(0), .image(0)],
        scene: &scene,
        makeID: {
            id += 1
            return "new-\(id)"
        })

    #expect(result.changed)
    #expect(result.audioClones == [TimelineAudioClone(sourceID: "audio", cloneID: "new-1")])
    #expect(scene.audioTracks[0].clips.count == 2)
    #expect(scene.audioTracks[0].clips[0].id == "audio")
    #expect(scene.audioTracks[0].clips[0].start == 0)
    #expect(scene.audioTracks[0].clips[0].dur == 3)
    #expect(scene.audioTracks[0].clips[0].offset == 2)
    #expect(scene.audioTracks[0].clips[0].fadeIn == 1)
    #expect(scene.audioTracks[0].clips[0].fadeOut == 0)
    #expect(scene.audioTracks[0].clips[1].id == "new-1")
    #expect(scene.audioTracks[0].clips[1].start == 7)
    #expect(scene.audioTracks[0].clips[1].dur == 3)
    #expect(scene.audioTracks[0].clips[1].offset == 9)
    #expect(scene.audioTracks[0].clips[1].fadeIn == 0)
    #expect(scene.audioTracks[0].clips[1].fadeOut == 1)

    #expect(scene.audioTracks[0].cues.count == 2)
    #expect(abs(scene.audioTracks[0].cues[0].to!.x - 0.3) < 1e-9)
    #expect(abs(scene.audioTracks[0].cues[1].from.x - 0.7) < 1e-9)
    #expect(scene.imageTracks[0].cues == [cue], "locked targets remain untouched")
}
