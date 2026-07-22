import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import BannyMedia
import BannyCore

@Test func contentDurationMatchesModelRules() {
    var state = SceneState()
    state.characters = [Character(body: .orange,
                                  clips: [AudioClip(id: "a", name: "a", start: 2, dur: 9, srcDur: 9)],
                                  events: [.key(t: 14.5, code: .keyM, down: true)])]
    #expect(ShowExporter.contentDuration(of: state) == 15.0)
}

@Test func resolveSegmentsFallsBackToWholeTimeline() {
    let doc = ShowDocument(stage: SceneState())
    let segs = ShowExporter.resolveSegments(document: doc)
    #expect(segs.count == 1)
    #expect(segs[0].from == 0)
}

@Test func backgroundCueResolution() {
    var stage = SceneState()
    stage.backgroundTracks = [BackgroundTrack(id: "b", name: "BG", cues: [
        BackgroundCue(id: "c1", assetID: "a1", start: 0, dur: 5),
        BackgroundCue(id: "c2", assetID: "a2", start: 5, dur: 5),
    ])]
    #expect(stage.activeBackgroundCue(at: 2)?.assetID == "a1")
    #expect(stage.activeBackgroundCue(at: 7)?.assetID == "a2")
    #expect(stage.activeBackgroundCue(at: 11) == nil)
    stage.backgroundTracks[0].hidden = true
    #expect(stage.activeBackgroundCue(at: 2) == nil)
}

@Test func imageCueInterpolates() {
    let cue = ImageCue(id: "i", assetID: "a", start: 2, dur: 4,
                       from: ImagePlacement(x: 0, y: 0, scale: 0.2, rotation: -30),
                       to: ImagePlacement(x: 1, y: 0.5, scale: 0.4, rotation: 90))
    #expect(cue.placement(at: 2) == ImagePlacement(x: 0, y: 0, scale: 0.2, rotation: -30))
    let mid = cue.placement(at: 4)
    #expect(abs(mid.x - 0.5) < 1e-9 && abs(mid.y - 0.25) < 1e-9
        && abs(mid.scale - 0.3) < 1e-9 && abs(mid.rotation - 30) < 1e-9)
    #expect(cue.placement(at: 99).x == 1)
}

@Test func floatingGIFUsesTheCueRelativeClock() throws {
    func frame(_ color: CGColor) -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 4,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data, UTType.gif.identifier as CFString, 2, nil))
    let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]]
    CGImageDestinationAddImage(destination, frame(CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                               properties as CFDictionary)
    CGImageDestinationAddImage(destination, frame(CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
                               properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("visual-\(UUID().uuidString).gif")
    try (data as Data).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let asset = Asset(id: "gif", name: "Loop", kind: .image, file: url.lastPathComponent)
    let sampler = ShowExporter.AssetSampler(assets: [asset], assetURL: { _ in url })
    let cue = ImageCue(id: "cue", assetID: asset.id, start: 10, dur: 5,
                       from: ImagePlacement())
    let first = try #require(sampler.visualFrame(cue: cue, at: 10.05))
    let second = try #require(sampler.visualFrame(cue: cue, at: 10.25))
    let looped = try #require(sampler.visualFrame(cue: cue, at: 10.45))
    #expect(first.dataProvider?.data as Data? != second.dataProvider?.data as Data?)
    #expect(first.dataProvider?.data as Data? == looped.dataProvider?.data as Data?)

    var continued = cue
    continued.playback = cue.continuedPlayback(at: 10.25)
    continued.start = 10.25
    let continuedFrame = try #require(sampler.visualFrame(cue: continued, at: continued.start))
    #expect(continuedFrame.dataProvider?.data as Data? == second.dataProvider?.data as Data?)

    var customized = cue
    customized.playback = MediaPlayback(trimStart: 0.2, trimEnd: 0.4,
                                        rate: 1, reverse: false, loop: false)
    let trimmed = try #require(sampler.visualFrame(cue: customized, at: 10))
    #expect(trimmed.dataProvider?.data as Data? == second.dataProvider?.data as Data?)

    customized.playback = MediaPlayback(trimStart: 0, trimEnd: 0.4,
                                        rate: 1, reverse: true, loop: false)
    let reversed = try #require(sampler.visualFrame(cue: customized, at: 10))
    #expect(reversed.dataProvider?.data as Data? == second.dataProvider?.data as Data?)

    customized.playback.freezeAt = 0.05
    let frozen = try #require(sampler.visualFrame(cue: customized, at: 13))
    #expect(frozen.dataProvider?.data as Data? == first.dataProvider?.data as Data?)
}
