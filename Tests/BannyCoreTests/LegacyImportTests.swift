import Foundation
import Testing
@testable import BannyCore

private let stagingPath = "/Users/jango/Documents/banny/show/ep1/beat1/staging/1.json"

@Test(.enabled(if: ep1Exists)) func importsRealEp1Staging() throws {
    let result = try V1Importer.importStudio(json: Data(contentsOf: URL(fileURLWithPath: stagingPath)))
    let doc = result.document

    #expect(doc.version == 4)
    // v3+ single timeline: DARL (Scene 2) + SAGE/HELIUS/TED (Scene 1).
    #expect(doc.stage.characters.map(\.name) == ["DARL", "SAGE", "HELIUS", "TED"])
    #expect(doc.stage.audioTracks.contains { $0.name == "SAGE" })

    // DARL carries the 923-event performance, sorted by time.
    let darl = try #require(doc.stage.characters.first { $0.name == "DARL" })
    #expect(darl.events.count == 923)
    #expect(zip(darl.events, darl.events.dropFirst()).allSatisfy { $0.t <= $1.t })
    #expect(darl.baseOutfit[5] == "fierce")
    #expect(darl.speed == 320)

    // Scene 1's characters were shifted past Scene 2's content.
    let sage = try #require(doc.stage.characters.first { $0.name == "SAGE" })
    if let first = sage.events.first { #expect(first.t > 30) }

    // Known clip from the inventory (Scene 2 = first, so unshifted).
    let clip = try #require(doc.stage.characters.flatMap(\.clips)
        .first { $0.id == "amr9n6hc4hwrot" })
    #expect(clip.name == "1-Darl")
    #expect(abs(clip.start - 0) < 1e-9)
    #expect(abs(clip.dur - 11.16) < 1e-9)
    #expect(abs(clip.srcDur - 25.208) < 1e-9)
    #expect(clip.fx.pan == .follow)

    // Backgrounds became bank assets + cues on one background track.
    #expect(!doc.assets.isEmpty)
    #expect(doc.stage.backgroundTracks.count == 1)
    #expect(doc.stage.backgroundTracks[0].cues.count == doc.assets.count)

    // Audio bytes decoded and look like mp3 (ID3 tag or MPEG frame sync).
    let bytes = try #require(result.audioFiles[clip.id])
    #expect(bytes.ext == "mp3")
    #expect(bytes.data.count > 10_000)
    let magic = [UInt8](bytes.data.prefix(3))
    #expect(magic == [0x49, 0x44, 0x33] || magic[0] == 0xFF, "unexpected audio magic \(magic)")

    // Positions normalized.
    for c in doc.stage.characters {
        #expect(c.x >= 0 && c.x <= 1.0001, "x \(c.x)")
        if let rs = c.recStart { #expect(rs.x >= 0 && rs.x <= 1.0001, "recStart.x \(rs.x)") }
    }
    for l in doc.stage.lights {
        #expect(l.x >= 0 && l.x <= 1 && l.y >= 0 && l.y <= 1)
    }
}

@Test func dataURLDecoding() throws {
    let media = try #require(V1Importer.decodeDataURL("data:audio/mpeg;base64,SUQz"))
    #expect(media.ext == "mp3")
    #expect([UInt8](media.data) == [0x49, 0x44, 0x33])
    #expect(V1Importer.decodeDataURL("not-a-data-url") == nil)
}

@Test func rejectsNonV1JSON() {
    #expect(throws: V1Importer.ImportError.notV1JSON) {
        _ = try V1Importer.importStudio(json: Data(#"{"hello":1}"#.utf8))
    }
}
