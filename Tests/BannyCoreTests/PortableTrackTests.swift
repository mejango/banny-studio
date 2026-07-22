import Foundation
import Testing
@testable import BannyCore

@Test func portableTrackRoundTripsEveryTrackKind() throws {
    let payloads: [PortableTrack.Payload] = [
        .character(Character(body: .pink, baseOutfit: [3: "flops"],
                             voicePitch: 2, voiceSpeed: 0.9,
                             events: [
                                 .outfit(t: 2, slot: 4, name: "ribbon"),
                                 .motion(t: 3, speed: 400, rotationSpeed: 900,
                                         wobble: nil, size: nil),
                             ],
                             name: "Sage", speed: 360, rotationSpeed: 720)),
        .audio(AudioTrack(id: "audio", name: "Media")),
        .image(ImageTrack(id: "image", name: "Props")),
        .light(LightTrack(id: "light", name: "Key light", cues: [
            LightCue(id: "light-cue", start: 0, dur: 4,
                     from: LightState(x: 0.2, y: 0.3)),
        ])),
        .background(BackgroundTrack(id: "scenes", name: "Scenes")),
    ]

    for payload in payloads {
        let archive = PortableTrack(payload: payload)
        let data = try archive.encoded()
        #expect(String(data: Data(data.prefix(8)), encoding: .ascii) == "bplist00")
        #expect(try PortableTrack(data: data) == archive)
    }
}

@Test func portableTrackRemapsIDsAndCarriesMedia() throws {
    let track = AudioTrack(
        id: "track-old",
        name: "Dialogue + card",
        clips: [
            AudioClip(id: "voice", name: "line, part 1", start: 0, dur: 1,
                      srcDur: 2),
            // Split clips intentionally share their source/media id.
            AudioClip(id: "voice", name: "line, part 2", start: 1, dur: 1,
                      offset: 1, srcDur: 2),
        ],
        cues: [
            ImageCue(id: "cue-a", assetID: "card", start: 0, dur: 1,
                     from: ImagePlacement(), speed: 8, rotationSpeed: 75),
            ImageCue(id: "cue-b", assetID: "card", start: 1, dur: 1,
                     from: ImagePlacement(x: 0.7), speed: 9, rotationSpeed: 100),
        ])
    let archive = PortableTrack(
        payload: .audio(track),
        assets: [Asset(id: "card", name: "Title card", kind: .image,
                       file: "card.png")],
        audio: ["voice": .init(data: Data([1, 2, 3]), fileExtension: "m4a")],
        assetMedia: ["card": .init(data: Data([4, 5]), fileExtension: "png")])

    var counter = 0
    let imported = try PortableTrack(data: archive.encoded()).remapped {
        counter += 1
        return "new-\(counter)"
    }

    guard case .audio(let remapped) = imported.payload else {
        Issue.record("Expected an audio track")
        return
    }
    #expect(remapped.id != track.id)
    #expect(Set(remapped.clips.map(\.id)).count == 1)
    #expect(remapped.clips[0].id != "voice")
    #expect(Set(remapped.cues.map(\.id)).count == 2)
    #expect(!remapped.cues.map(\.id).contains("cue-a"))
    #expect(Set(remapped.cues.map(\.assetID)).count == 1)
    #expect(remapped.cues[0].assetID != "card")
    #expect(remapped.cues.map(\.speed) == [8, 9])
    #expect(remapped.cues.map(\.rotationSpeed) == [75, 100])

    let newAudioID = remapped.clips[0].id
    let newAssetID = remapped.cues[0].assetID
    #expect(imported.audio[newAudioID]?.data == Data([1, 2, 3]))
    #expect(imported.assetMedia[newAssetID]?.data == Data([4, 5]))
    #expect(imported.assets == [Asset(id: newAssetID, name: "Title card",
                                     kind: .image, file: "\(newAssetID).png")])
    #expect(archive.payload == .audio(track))
}

@Test func portableTrackRejectsMissingDependencies() {
    let missingAudio = PortableTrack(payload: .character(Character(
        body: .orange,
        clips: [AudioClip(id: "voice", name: "line", start: 0, dur: 1, srcDur: 1)])))
    #expect(throws: PortableTrackError.missingAudio("voice")) {
        _ = try missingAudio.encoded()
    }

    let missingAsset = PortableTrack(payload: .image(ImageTrack(
        id: "images", name: "Images",
        cues: [ImageCue(id: "cue", assetID: "poster", start: 0, dur: 1,
                        from: ImagePlacement())])))
    #expect(throws: PortableTrackError.missingAsset("poster")) {
        _ = try missingAsset.encoded()
    }
}

@Test func portableCharacterCarriesAndRemapsReactionDefinitions() throws {
    let definition = ReactionDefinition(id: "reaction-old", name: "Double take", dur: 1,
                                        events: [.outfit(t: 0.2, slot: 12,
                                                         name: "chef-hat")])
    let character = Character(body: .orange, reactions: [
        ReactionInstance(id: "block-old", reactionID: definition.id,
                         start: 2, dur: 1.5),
    ])
    let archive = PortableTrack(payload: .character(character),
                                reactionLibrary: [definition])
    var counter = 0
    let remapped = try PortableTrack(data: archive.encoded()).remapped {
        counter += 1
        return "new-\(counter)"
    }
    guard case .character(let imported) = remapped.payload else {
        Issue.record("Expected character")
        return
    }
    #expect(remapped.reactionLibrary.count == 1)
    #expect(remapped.reactionLibrary[0].id != definition.id)
    #expect(imported.reactions[0].id != "block-old")
    #expect(imported.reactions[0].reactionID == remapped.reactionLibrary[0].id)

    let broken = PortableTrack(payload: .character(character))
    #expect(throws: PortableTrackError.missingReaction("reaction-old")) {
        _ = try broken.encoded()
    }
}
