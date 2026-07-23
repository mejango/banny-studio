# Banny CLI Companion + AI Production Skill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `banny-tool` into `banny`, an agent-facing CLI (catalog / new / validate / preview / info --json / ship / skill) plus a SKILL.md that teaches any AI agent end-to-end show production.

**Architecture:** New logic lives in the libraries where it's testable — catalog summary in `BannyRender`, lint in `BannyRender`, starter doc in `BannyCore`, preview in `BannyMedia` — and the CLI target only parses args and wires them together. The SKILL text is a Swift string constant in the CLI (single binary, no resource bundle), mirrored to `skills/banny-studio/SKILL.md` with a test that they match.

**Tech Stack:** Swift 6.1 SPM, XCTest, CoreGraphics/ImageIO. No new dependencies.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-21-cli-companion-ai-skill-design.md`.
- Do NOT touch the uncommitted WIP files (`App/Sources/EditorView.swift`, `ShipView.swift`, `TimelineView.swift`, `WardrobePanel.swift`, `App/Info.plist`, `App/project.yml`, `Sources/BannyMedia/ShowExporter.swift`, `App/Sources/TrackTransfer.swift`, `Sources/BannyCore/PortableTrack.swift`, `Tests/BannyCoreTests/PortableTrackTests.swift`) except where a task explicitly says so, and commit only the files each task names.
- Task 5 reads `ShowExporter.Options.p480`, which exists only in the uncommitted `ShowExporter.swift` WIP. If it's missing when you get there, add it (code included in Task 5).
- Times are seconds; JSON is the exact Codable output of `ShowDocument` (sorted keys, pretty-printed).
- Run tests with `swift test --filter <TestClass>` from the repo root.
- Commit messages: `feat(cli): …` style, each ending with the Claude co-author trailer.

---

### Task 1: Catalog summary (`banny catalog`)

**Files:**
- Modify: `Sources/BannyRender/AssetCatalog.swift` (append at end of class)
- Test: `Tests/BannyRenderTests/CatalogSummaryTests.swift` (create)
- Modify: `Sources/banny-tool/main.swift`

**Interfaces:**
- Consumes: `AssetCatalog` internals (`catalog: CatalogFile`), existing `outfits(inSlot:)`, `slotName(_:)`.
- Produces: `AssetCatalog.Summary` (Codable) and `func summary() -> Summary` — Task 6's SKILL text tells agents to call `banny catalog --json` which encodes this type.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BannyRenderTests/CatalogSummaryTests.swift
import XCTest
@testable import BannyRender

final class CatalogSummaryTests: XCTestCase {
    static let assetsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets")

    func testSummaryListsBodiesAndOutfitsAndRoundTripsJSON() throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let summary = catalog.summary()
        XCTAssertTrue(summary.bodies.contains("orange"))
        XCTAssertFalse(summary.slots.isEmpty)
        for slot in summary.slots {
            XCTAssertFalse(slot.outfits.isEmpty, "slot \(slot.slot) has no outfits")
        }
        XCTAssertFalse(summary.eyes.isEmpty)
        XCTAssertFalse(summary.mouths.isEmpty)

        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(AssetCatalog.Summary.self, from: data)
        XCTAssertEqual(decoded.bodies, summary.bodies)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CatalogSummaryTests`
Expected: FAIL — `Summary` / `summary()` not defined.

- [ ] **Step 3: Implement**

Append inside `AssetCatalog` (before the final `}` of the class):

```swift
    // MARK: - Machine-readable summary (banny catalog)

    /// Everything an agent needs to pick wardrobe: names are the values that
    /// go into `baseOutfit` / outfit events; labels are for humans.
    public struct Summary: Codable, Sendable {
        public struct Outfit: Codable, Sendable {
            public var name: String
            public var label: String
        }
        public struct SlotEntry: Codable, Sendable {
            public var slot: Int
            public var name: String
            public var outfits: [Outfit]
        }
        public var bodies: [String]
        public var slots: [SlotEntry]
        public var eyes: [String]
        public var mouths: [String]
        /// Verbatim exclusivity table from the catalog (key → conflicting slots).
        public var exclusivity: [String: [Int]]
    }

    public func summary() -> Summary {
        let slotIDs = Set(catalog.outfits.values.map(\.slot)).sorted()
        return Summary(
            bodies: catalog.bodies.keys.sorted(),
            slots: slotIDs.map { id in
                Summary.SlotEntry(slot: id,
                                  name: slotName(id) ?? "slot \(id)",
                                  outfits: outfits(inSlot: id).map { Summary.Outfit(name: $0.name, label: $0.label) })
            },
            eyes: catalog.eyes.keys.sorted(),
            mouths: catalog.mouths.keys.sorted(),
            exclusivity: catalog.exclusivity)
    }
```

Note: `catalog.eyes` / `catalog.mouths` / `catalog.exclusivity` are internal properties of the internal `CatalogFile` — same file, so direct access compiles.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CatalogSummaryTests`
Expected: PASS

- [ ] **Step 5: Wire the subcommand**

In `Sources/banny-tool/main.swift`, add a case before `default:`:

```swift
case "catalog":
    let catalog = try AssetCatalog(assetsRoot: locateAssetsRoot())
    let summary = catalog.summary()
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        print(String(data: try enc.encode(summary), encoding: .utf8)!)
    } else {
        print("bodies: \(summary.bodies.joined(separator: ", "))")
        for slot in summary.slots {
            print("\n\(slot.name) (slot \(slot.slot)):")
            for o in slot.outfits { print("  \(o.name) — \(o.label)") }
        }
        print("\neyes: \(summary.eyes.joined(separator: ", "))")
        print("mouths: \(summary.mouths.joined(separator: ", "))")
    }
```

Add `import BannyRender` at the top of `main.swift` if not present, and a temporary asset locator at the bottom of `main.swift` (Task 5 moves it to its own file — put it there now):

Create `Sources/banny-tool/assets.swift`:

```swift
import Foundation

enum CLIError: Error, CustomStringConvertible {
    case assetsNotFound
    case usage(String)

    var description: String {
        switch self {
        case .assetsNotFound:
            return """
            Banny assets not found. Install Banny Studio from the App Store, or set
            BANNY_ASSETS to a folder containing catalog.json + png/.
            """
        case .usage(let u): return "usage: \(u)"
        }
    }
}

/// $BANNY_ASSETS → installed app bundle → repo checkout (dev).
func locateAssetsRoot() throws -> URL {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let env = ProcessInfo.processInfo.environment["BANNY_ASSETS"] {
        candidates.append(URL(fileURLWithPath: env))
    }
    for app in ["/Applications/Banny Studio.app", "/Applications/BannyStudio.app"] {
        candidates.append(URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/BannyAssets"))
    }
    candidates.append(URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets"))
    for url in candidates where fm.fileExists(atPath: url.appendingPathComponent("catalog.json").path) {
        return url
    }
    throw CLIError.assetsNotFound
}
```

Update the `default:` usage line to include `catalog [--json]`.

- [ ] **Step 6: Smoke-run and commit**

Run: `swift run banny-tool catalog | head -20` → bodies line + at least one slot section.
Run: `swift run banny-tool catalog --json | head -5` → JSON object.

```bash
git add Sources/BannyRender/AssetCatalog.swift Tests/BannyRenderTests/CatalogSummaryTests.swift Sources/banny-tool/main.swift Sources/banny-tool/assets.swift
git commit -m "feat(cli): banny catalog — wardrobe summary for agents"
```

---

### Task 2: Lint (`banny validate`)

**Files:**
- Create: `Sources/BannyRender/ShowLint.swift`
- Test: `Tests/BannyRenderTests/ShowLintTests.swift`
- Modify: `Sources/banny-tool/main.swift`

**Interfaces:**
- Consumes: `ShowDocument`/`SceneState`/`PerfEvent` from BannyCore, `AssetCatalog.outfitSlot(_:)` from Task 1's file (pre-existing method).
- Produces: `ShowLint.Diagnostic` (Codable: `severity` `"error"|"warning"`, `message`) and `ShowLint.check(document:audioIDs:assetFileIDs:catalog:) -> [Diagnostic]`. Task 3's test and Task 6's SKILL rely on `validate` exiting 0 on clean docs, 1 on errors.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BannyRenderTests/ShowLintTests.swift
import XCTest
import BannyCore
@testable import BannyRender

final class ShowLintTests: XCTestCase {
    static let assetsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets")

    func testCleanDocumentHasNoDiagnostics() throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let doc = ShowDocument(stage: SceneState(characters: [Character(body: .orange)]))
        XCTAssertEqual(ShowLint.check(document: doc, audioIDs: [], assetFileIDs: [], catalog: catalog), [])
    }

    func testSeededErrorsAreCaught() throws {
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        var banny = Character(body: .orange, name: "Banny 1")
        banny.baseOutfit = [4: "no-such-outfit"]
        banny.events = [.key(t: -1, code: .keyM, down: true)]
        banny.clips = [AudioClip(id: "missing-audio", name: "voice", start: 0, dur: 2, srcDur: 2)]
        var doc = ShowDocument(stage: SceneState(characters: [banny]))
        doc.stage.imageTracks = [ImageTrack(id: "img1", name: "Images", cues: [
            ImageCue(id: "cue1", assetID: "ghost-asset", start: 0, dur: 1),
        ])]
        doc.assets = [Asset(id: "unfiled", name: "logo", kind: .image, file: "unfiled.png")]

        let diags = ShowLint.check(document: doc, audioIDs: [], assetFileIDs: [], catalog: catalog)
        let messages = diags.map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("no-such-outfit"), messages)
        XCTAssertTrue(messages.contains("t=-1"), messages)
        XCTAssertTrue(messages.contains("missing-audio"), messages)
        XCTAssertTrue(messages.contains("ghost-asset"), messages)
        XCTAssertTrue(messages.contains("unfiled"), messages)
        XCTAssertTrue(diags.allSatisfy { $0.severity == .error })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ShowLintTests`
Expected: FAIL — `ShowLint` not defined.

- [ ] **Step 3: Implement**

```swift
// Sources/BannyRender/ShowLint.swift
import Foundation
import BannyCore

/// Semantic checks an agent runs before shipping. Decode failures are the
/// caller's problem (they throw earlier); this catches what decodes fine but
/// renders wrong or silently drops content.
public enum ShowLint {
    public struct Diagnostic: Codable, Equatable, Sendable {
        public enum Severity: String, Codable, Sendable { case error, warning }
        public var severity: Severity
        public var message: String

        public init(_ severity: Severity, _ message: String) {
            self.severity = severity
            self.message = message
        }
    }

    /// - Parameters:
    ///   - audioIDs: clip ids that have a file in the package's `audio/`.
    ///   - assetFileIDs: asset ids that have a file in the package's `assets/`.
    ///   - catalog: nil skips wardrobe-name checks (assets unavailable).
    public static func check(document: ShowDocument,
                             audioIDs: Set<String>,
                             assetFileIDs: Set<String>,
                             catalog: AssetCatalog?) -> [Diagnostic] {
        var out: [Diagnostic] = []
        let stage = document.stage
        let bankIDs = Set(document.assets.map(\.id))

        for (i, ch) in stage.characters.enumerated() {
            let who = ch.name.isEmpty ? "character \(i + 1)" : ch.name
            if let catalog {
                for (slot, name) in ch.baseOutfit.sorted(by: { $0.key < $1.key })
                    where catalog.outfitSlot(name) == nil {
                    out.append(.init(.error, "\(who): baseOutfit slot \(slot) references unknown outfit \"\(name)\" — run `banny catalog` for valid names"))
                }
            }
            for event in ch.events {
                if event.t < 0 {
                    out.append(.init(.error, "\(who): event at t=\(clean(event.t)) is before 0"))
                }
                if case .outfit(_, let slot, let name) = event, let name, let catalog {
                    switch catalog.outfitSlot(name) {
                    case nil:
                        out.append(.init(.error, "\(who): outfit event references unknown outfit \"\(name)\""))
                    case .some(let actual) where actual != slot:
                        out.append(.init(.warning, "\(who): outfit \"\(name)\" belongs to slot \(actual), event says slot \(slot)"))
                    default: break
                    }
                }
            }
            checkClips(ch.clips, owner: who, audioIDs: audioIDs, into: &out)
            checkCues(ch.subs.map { ("subtitle \"\($0.text)\"", $0.start, $0.dur) }, owner: who, into: &out)
        }

        for track in stage.audioTracks {
            checkClips(track.clips, owner: "track \"\(track.name)\"", audioIDs: audioIDs, into: &out)
            checkAssetRefs(track.cues.map { ($0.id, $0.assetID, $0.start, $0.dur) },
                           owner: "track \"\(track.name)\"", bankIDs: bankIDs, into: &out)
        }
        for track in stage.imageTracks {
            checkAssetRefs(track.cues.map { ($0.id, $0.assetID, $0.start, $0.dur) },
                           owner: "image track \"\(track.name)\"", bankIDs: bankIDs, into: &out)
        }
        for track in stage.backgroundTracks {
            checkAssetRefs(track.cues.map { ($0.id, $0.assetID, $0.start, $0.dur) },
                           owner: "background track \"\(track.name)\"", bankIDs: bankIDs, into: &out)
        }
        for asset in document.assets where !assetFileIDs.contains(asset.id) {
            out.append(.init(.error, "asset \"\(asset.name)\" (\(asset.id)) has no file in assets/"))
        }
        return out
    }

    private static func checkClips(_ clips: [AudioClip], owner: String,
                                   audioIDs: Set<String>, into out: inout [Diagnostic]) {
        for clip in clips {
            if !audioIDs.contains(clip.id) {
                out.append(.init(.error, "\(owner): audio clip \"\(clip.name)\" (\(clip.id)) has no file in audio/"))
            }
            if clip.dur <= 0 {
                out.append(.init(.error, "\(owner): audio clip \"\(clip.name)\" has non-positive duration \(clean(clip.dur))"))
            }
        }
    }

    private static func checkCues(_ items: [(label: String, start: Double, dur: Double)],
                                  owner: String, into out: inout [Diagnostic]) {
        for item in items where item.dur <= 0 || item.start < 0 {
            out.append(.init(.error, "\(owner): \(item.label) has invalid range start=\(clean(item.start)) dur=\(clean(item.dur))"))
        }
    }

    private static func checkAssetRefs(_ cues: [(id: String, assetID: String, start: Double, dur: Double)],
                                       owner: String, bankIDs: Set<String>, into out: inout [Diagnostic]) {
        for cue in cues {
            if !bankIDs.contains(cue.assetID) {
                out.append(.init(.error, "\(owner): cue \(cue.id) references unknown asset \"\(cue.assetID)\""))
            }
            if cue.dur <= 0 || cue.start < 0 {
                out.append(.init(.error, "\(owner): cue \(cue.id) has invalid range start=\(clean(cue.start)) dur=\(clean(cue.dur))"))
            }
        }
    }

    private static func clean(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ShowLintTests`
Expected: PASS

- [ ] **Step 5: Wire the subcommand**

In `main.swift` add:

```swift
case "validate":
    guard args.count >= 3 else { throw CLIError.usage("banny validate <show.bs> [--json]") }
    let contents = try ShowPackage.read(from: URL(fileURLWithPath: args[2]))
    let catalog = try? AssetCatalog(assetsRoot: locateAssetsRoot())
    let diags = ShowLint.check(document: contents.document,
                               audioIDs: Set(contents.audioURLs.keys),
                               assetFileIDs: Set(contents.assetURLs.keys),
                               catalog: catalog)
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        print(String(data: try enc.encode(diags), encoding: .utf8)!)
    } else if diags.isEmpty {
        print("ok — no issues")
    } else {
        for d in diags { print("\(d.severity.rawValue): \(d.message)") }
    }
    if catalog == nil { print("note: assets not found — wardrobe names not checked") }
    exit(diags.contains { $0.severity == .error } ? 1 : 0)
```

- [ ] **Step 6: Smoke-run and commit**

Run: `swift run banny-tool validate ep1.bannyshow && echo CLEAN` → diagnostics or `ok — no issues` + `CLEAN` (repo fixture should be clean; if it reports real issues, that's signal, not failure — just confirm exit code matches).

```bash
git add Sources/BannyRender/ShowLint.swift Tests/BannyRenderTests/ShowLintTests.swift Sources/banny-tool/main.swift
git commit -m "feat(cli): banny validate — semantic lint with JSON diagnostics"
```

---

### Task 3: Starter document (`banny new`)

**Files:**
- Create: `Sources/BannyCore/StarterDocument.swift`
- Test: `Tests/BannyCoreTests/StarterDocumentTests.swift`
- Modify: `Sources/banny-tool/main.swift`

**Interfaces:**
- Consumes: `ShowDocument`, `SceneState`, `Character`, `Body` (BannyCore).
- Produces: `ShowDocument.starter(characterCount:) -> ShowDocument`. Task 6's SKILL instructs `banny new out.bs --characters N`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BannyCoreTests/StarterDocumentTests.swift
import XCTest
@testable import BannyCore

final class StarterDocumentTests: XCTestCase {
    func testStarterRoundTripsThroughPackage() throws {
        let doc = ShowDocument.starter(characterCount: 2)
        XCTAssertEqual(doc.stage.characters.count, 2)
        XCTAssertEqual(doc.stage.characters.map(\.name), ["Banny 1", "Banny 2"])
        XCTAssertNotEqual(doc.stage.characters[0].x, doc.stage.characters[1].x)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("starter-\(UUID().uuidString).bs")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ShowPackage.write(doc, to: dir)
        let reread = try ShowPackage.read(from: dir)
        XCTAssertEqual(reread.document, doc)
    }

    func testStarterClampsCount() {
        XCTAssertEqual(ShowDocument.starter(characterCount: 0).stage.characters.count, 1)
        XCTAssertEqual(ShowDocument.starter(characterCount: 99).stage.characters.count, 4)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StarterDocumentTests`
Expected: FAIL — `starter` not defined.

- [ ] **Step 3: Implement**

```swift
// Sources/BannyCore/StarterDocument.swift
public extension ShowDocument {
    /// Minimal valid document for `banny new`: N bannys spread across the
    /// stage facing center, everything else default. Agents edit show.json
    /// from here instead of authoring from a blank page.
    static func starter(characterCount: Int = 2) -> ShowDocument {
        let bodies: [Body] = [.orange, .pink, .alien, .original]
        let n = max(1, min(4, characterCount))
        let characters = (0..<n).map { i -> Character in
            let x = n == 1 ? 0.5 : 0.25 + 0.5 * Double(i) / Double(n - 1)
            return Character(body: bodies[i % bodies.count],
                             x: x,
                             face: x <= 0.5 ? 1 : -1,
                             name: "Banny \(i + 1)")
        }
        return ShowDocument(stage: SceneState(characters: characters))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StarterDocumentTests`
Expected: PASS

- [ ] **Step 5: Wire the subcommand**

In `main.swift` add:

```swift
case "new":
    guard args.count >= 3 else { throw CLIError.usage("banny new <out.bs> [--characters N]") }
    let out = URL(fileURLWithPath: args[2])
    guard !FileManager.default.fileExists(atPath: out.path) else {
        print("error: \(out.path) already exists"); exit(1)
    }
    let count = args.firstIndex(of: "--characters").flatMap { i in
        args.indices.contains(i + 1) ? Int(args[i + 1]) : nil
    } ?? 2
    try ShowPackage.write(.starter(characterCount: count), to: out)
    print("created \(out.path) — edit show.json, then `banny validate` before shipping")
```

- [ ] **Step 6: Smoke-run and commit**

Run:
```bash
swift run banny-tool new /tmp/starter-test.bs --characters 3
swift run banny-tool validate /tmp/starter-test.bs && rm -rf /tmp/starter-test.bs
```
Expected: `created …`, then `ok — no issues`.

```bash
git add Sources/BannyCore/StarterDocument.swift Tests/BannyCoreTests/StarterDocumentTests.swift Sources/banny-tool/main.swift
git commit -m "feat(cli): banny new — known-good starter project"
```

---

### Task 4: Frame preview (`banny preview`)

**Files:**
- Create: `Sources/BannyMedia/ShowPreview.swift`
- Test: `Tests/BannyMediaTests/ShowPreviewTests.swift`
- Modify: `Sources/banny-tool/main.swift`

**Interfaces:**
- Consumes: `FrameRenderer.draw(scene:at:size:background:imageAsset:flipped:in:)`, internal `ShowExporter.BackgroundSampler` / `ShowExporter.StillAssetCache` (same module), `ShowExporter.Options.p1080.fitted(aspect:)`, `ShowPackage.Contents`.
- Produces: `ShowPreview.writePNG(contents:assets:at:to:)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BannyMediaTests/ShowPreviewTests.swift
import XCTest
import BannyCore
import BannyRender
@testable import BannyMedia

final class ShowPreviewTests: XCTestCase {
    static let assetsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets")

    func testPreviewWritesDecodablePNG() throws {
        let assets = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let doc = ShowDocument.starter(characterCount: 2)
        let contents = ShowPackage.Contents(document: doc, audioURLs: [:], assetURLs: [:])
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }

        try ShowPreview.writePNG(contents: contents, assets: assets, at: 0, to: out)

        let src = CGImageSourceCreateWithURL(out as CFURL, nil)
        let image = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(image?.width, 1920)
        XCTAssertEqual(image?.height, 1080)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ShowPreviewTests`
Expected: FAIL — `ShowPreview` not defined.

- [ ] **Step 3: Implement**

```swift
// Sources/BannyMedia/ShowPreview.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import BannyCore
import BannyRender

/// One frame of a show as a PNG — an agent's eyes before a full `ship`.
public enum ShowPreview {
    public enum PreviewError: Error { case contextFailed, encodeFailed }

    public static func writePNG(contents: ShowPackage.Contents,
                                assets: AssetCatalog,
                                at t: Double,
                                to url: URL) throws {
        let document = contents.document
        let options = ShowExporter.Options.p1080.fitted(aspect: document.settings.frameAspect)
        let width = Int(options.size.width), height = Int(options.size.height)
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PreviewError.contextFailed
        }
        let bg = ShowExporter.BackgroundSampler(assets: document.assets,
                                                assetURL: { contents.assetURLs[$0] })
        let stills = ShowExporter.StillAssetCache(assets: document.assets,
                                                  assetURL: { contents.assetURLs[$0] })
        FrameRenderer(assets: assets).draw(
            scene: document.stage, at: t, size: options.size,
            background: document.stage.activeBackgroundCue(at: t).flatMap { bg.frame(cue: $0, at: t) },
            imageAsset: { stills.image(for: $0) },
            flipped: true, in: ctx)

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw PreviewError.encodeFailed }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw PreviewError.encodeFailed }
    }
}
```

If `BackgroundSampler.frame(cue:at:)`'s return type doesn't literally match `FrameRenderer.draw`'s `background:` tuple parameter, adapt at the call site the same way `ShowExporter.export` does at `Sources/BannyMedia/ShowExporter.swift:176` — copy that exact expression.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ShowPreviewTests`
Expected: PASS

- [ ] **Step 5: Wire the subcommand**

In `main.swift` add:

```swift
case "preview":
    guard args.count >= 4 else { throw CLIError.usage("banny preview <show.bs> <out.png> [--t SECONDS]") }
    let t = args.firstIndex(of: "--t").flatMap { i in
        args.indices.contains(i + 1) ? Double(args[i + 1]) : nil
    } ?? 0
    let contents = try ShowPackage.read(from: URL(fileURLWithPath: args[2]))
    let assets = try AssetCatalog(assetsRoot: locateAssetsRoot())
    try ShowPreview.writePNG(contents: contents, assets: assets, at: t,
                             to: URL(fileURLWithPath: args[3]))
    print("wrote \(args[3]) @ t=\(t)s")
```

(`import BannyMedia` is already in `ship.swift`; add to `main.swift` if the compiler asks.)

- [ ] **Step 6: Smoke-run and commit**

Run: `swift run banny-tool preview ep1.bannyshow /tmp/ep1-t2.png --t 2 && file /tmp/ep1-t2.png`
Expected: `PNG image data, 1920 x 1080` (or the doc's aspect).

```bash
git add Sources/BannyMedia/ShowPreview.swift Tests/BannyMediaTests/ShowPreviewTests.swift Sources/banny-tool/main.swift
git commit -m "feat(cli): banny preview — render one frame to PNG"
```

---

### Task 5: `info --json`, `ship --480/--range`, asset locator in ship, product rename to `banny`

**Files:**
- Modify: `Sources/banny-tool/main.swift`
- Modify: `Sources/banny-tool/ship.swift`
- Modify: `Package.swift:11`
- Modify (only if `p480` is absent): `Sources/BannyMedia/ShowExporter.swift`

**Interfaces:**
- Consumes: `ShowExporter.Options.p480` (from the export-preferences WIP), `ShowSegment(name:from:to:)`, `locateAssetsRoot()` from Task 1.
- Produces: product name `banny` (`swift run banny …`); `ship` flags `--480 --720 --1080 --4k --range A B`.

- [ ] **Step 1: Rename the product**

In `Package.swift` line 11:

```swift
        .executable(name: "banny", targets: ["banny-tool"]),
```

Run: `swift run banny 2>&1 | head -2` → the usage line (target dir stays `banny-tool`; only the product name changes).

- [ ] **Step 2: `info --json`**

Replace the `case "info":` body in `main.swift` with:

```swift
case "info":
    guard args.count >= 3 else { throw CLIError.usage("banny info <show.bs> [--json]") }
    let contents = try ShowPackage.read(from: URL(fileURLWithPath: args[2]))
    let st = contents.document.stage
    if args.contains("--json") {
        struct Info: Codable {
            var characters: Int; var events: Int; var audioTracks: Int
            var imageTracks: Int; var backgroundTracks: Int
            var assets: Int; var contentEnd: Double
            var characterNames: [String]
        }
        let info = Info(characters: st.characters.count,
                        events: st.characters.map(\.events.count).reduce(0, +),
                        audioTracks: st.audioTracks.count,
                        imageTracks: st.imageTracks.count,
                        backgroundTracks: st.backgroundTracks.count,
                        assets: contents.document.assets.count,
                        contentEnd: st.contentEnd,
                        characterNames: st.characters.map(\.name))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        print(String(data: try enc.encode(info), encoding: .utf8)!)
    } else {
        print("tracks: \(st.characters.count) characters (\(st.characters.map(\.events.count).reduce(0,+)) events), \(st.audioTracks.count) audio, \(st.imageTracks.count) image, \(st.backgroundTracks.count) background; \(contents.document.assets.count) assets; end \(st.contentEnd)s")
    }
```

- [ ] **Step 3: `ship` flags + locator**

Replace `Sources/banny-tool/ship.swift`'s body:

```swift
import Foundation
import BannyCore
import BannyRender
import BannyMedia

func shipCommand(_ args: [String]) throws {
    // banny ship <show.bs> <out.mp4> [--480|--720|--1080|--4k] [--range FROM TO]
    guard args.count >= 2 else {
        throw CLIError.usage("banny ship <show.bs> <out.mp4> [--480|--720|--1080|--4k] [--range FROM TO]")
    }
    let pkgURL = URL(fileURLWithPath: args[0])
    let outURL = URL(fileURLWithPath: args[1])
    let tier: ShowExporter.Options = args.contains("--480") ? .p480
        : args.contains("--720") ? .p720
        : args.contains("--4k") ? .p2160 : .p1080

    var contents = try ShowPackage.read(from: pkgURL)
    if let i = args.firstIndex(of: "--range"), args.indices.contains(i + 2),
       let from = Double(args[i + 1]), let to = Double(args[i + 2]), to > from {
        contents.document.show = [ShowSegment(name: "range", from: from, to: to)]
    }
    let options = tier.fitted(aspect: contents.document.settings.frameAspect)
    let assets = try AssetCatalog(assetsRoot: locateAssetsRoot())

    let clock = ContinuousClock()
    let elapsed = try clock.measure {
        try ShowExporter.export(
            document: contents.document,
            assets: assets,
            audioURL: { contents.audioURLs[$0] },
            assetURL: { contents.assetURLs[$0] },
            options: options,
            to: outURL,
            progress: { p in
                if Int(p * 100) % 20 == 0 { print("  \(Int(p * 100))%", terminator: "\r") }
            })
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int).flatMap { $0 } ?? 0
    print("shipped \(outURL.lastPathComponent): \(size) bytes in \(elapsed)")
}
```

Only if `ShowExporter.Options.p480` doesn't exist (WIP not present), add next to `p720` in `ShowExporter.swift`:

```swift
        public static let p480 = Options(size: CGSize(width: 854, height: 480), videoBitrate: 1_500_000)
```

- [ ] **Step 4: Update the usage string**

In `main.swift`'s `default:`:

```swift
default:
    print("""
    usage: banny <command>
      catalog [--json]                                — wardrobe options (bodies, outfits, eyes, mouths)
      new <out.bs> [--characters N]                   — create a starter project
      validate <show.bs> [--json]                     — lint; exit 1 on errors
      preview <show.bs> <out.png> [--t SECONDS]       — render one frame
      info <show.bs> [--json]                         — track/event/asset counts
      ship <show.bs> <out.mp4> [--480|--720|--1080|--4k] [--range FROM TO]
      import <v1.json> <out.bannyshow>                — web v1 → native
      stylize <in.png> <out.png> [gridWidth]          — pixel-art stylizer
      skill [install|print]                           — the AI production skill
    """)
    exit(1)
```

(`skill` lands in Task 6 — listing it now keeps this string final.)

- [ ] **Step 5: Verify + full test pass + commit**

```bash
swift run banny info ep1.bannyshow --json
swift run banny ship ep1-beat1.bannyshow /tmp/beat1.mp4 --480 --range 0 2
swift test
```
Expected: JSON info; a small mp4 (~2s, well under 1 MB); all tests pass.

```bash
git add Package.swift Sources/banny-tool/main.swift Sources/banny-tool/ship.swift
git commit -m "feat(cli): rename product to banny; info --json; ship --480/--range"
```
If `p480` was added, include `Sources/BannyMedia/ShowExporter.swift` ONLY when the WIP hunks aren't in it — never commit the unrelated WIP; use `git add -p` to stage just the `p480` line if needed.

---

### Task 6: The SKILL (`banny skill`) — the product

**Files:**
- Create: `Sources/banny-tool/skill.swift` (canonical skill text + subcommand)
- Create: `skills/banny-studio/SKILL.md` (repo mirror, generated)
- Test: `Tests/BannyCoreTests/SkillMirrorTests.swift`
- Modify: `Sources/banny-tool/main.swift`

**Interfaces:**
- Consumes: nothing from other tasks at compile time; the text references every command shipped in Tasks 1–5.
- Produces: `let skillMarkdown: String`, `func skillCommand(_ args: [String]) throws`. The repo file `skills/banny-studio/SKILL.md` must equal `skillMarkdown` byte-for-byte.

- [ ] **Step 1: Write the skill text and subcommand**

Create `Sources/banny-tool/skill.swift`. The markdown below is the deliverable — copy it exactly:

```swift
import Foundation

// Canonical skill text. skills/banny-studio/SKILL.md mirrors this string —
// regenerate with: swift run banny skill print > skills/banny-studio/SKILL.md
let skillMarkdown = #"""
---
name: banny-studio
description: Produce Banny Studio shows from the command line — author .bs projects, validate them, preview frames, and render mp4s headlessly with the banny CLI. Use when asked to make, render, or automate a Banny show, episode, cartoon, or banny studio production.
---

# Banny Studio Production

Banny Studio is a macOS pixel-art puppet studio. A show is a `.bs` directory
package you can author directly as JSON, then render to mp4 with the `banny`
CLI — no GUI needed. You write the script and audio; `banny` is your eyes
(catalog, validate, preview) and your renderer (ship).

## Setup

Check the CLI exists: `banny` (bare, prints usage). If missing:

    brew install mejango/banny/banny

Wardrobe art comes from the Banny Studio app (App Store). If `banny catalog`
reports missing assets, install the app or set `BANNY_ASSETS`.

## The production loop

1. `banny catalog --json` — learn the wardrobe. NEVER guess outfit names.
2. `banny new show.bs --characters 2` — start from a known-good project.
3. Edit `show.bs/show.json`; drop audio files into `show.bs/audio/`,
   images into `show.bs/assets/`.
4. `banny validate show.bs` — fix every error (exit 1 = errors).
5. `banny preview show.bs check.png --t 2.5` — look at key moments.
6. `banny ship show.bs out.mp4 [--480|--720|--1080|--4k] [--range FROM TO]`

Always validate before shipping. Preview at least one frame per scene beat.

## The .bs package

    show.bs/
      show.json          — the document (all structure lives here)
      audio/<id>.<ext>   — audio sources; <id> must match a clip id
      assets/<id>.<ext>  — images/videos; <id> must match an asset id

`show.json` top level: `{version: 4, stage, assets, show, settings}`.
All times are seconds. The timeline ends at the last event/clip/cue.

- `settings`: `{activeScene, lightSize, frameW, frameH}` — frameW×frameH
  sets aspect (16:9 default; 1080×1920 for vertical shorts).
- `assets`: `[{id, name, kind: "image"|"video", file}]` — the bank; `file`
  names the extension used in `assets/`.
- `show`: `[{name, from, to}]` — optional playlist segments; empty = whole
  timeline.

## Characters (stage.characters[])

    {
      "body": "orange",            // banny catalog: bodies
      "x": 0.35,                   // 0..1 across the stage
      "depth": 0,                  // >0 farther/smaller, <0 closer
      "size": 1,                   // 1 normal, 0.62 small, 0.38 baby
      "face": 1,                   // 1 → faces right, -1 → faces left
      "name": "Coach",
      "baseOutfit": {"4": "banny_vision_pro"},   // slot → outfit name, at t=0
      "events": [...],             // the performance (below)
      "clips": [...],              // this character's voice audio
      "subs": [{"text": "GOAL!", "start": 1.2, "dur": 2.0}],
      "voicePitch": 0, "voiceSpeed": 1
    }

Outfit names and slot numbers MUST come from `banny catalog --json`
(`slots[].outfits[].name`). Unknown names fail validate.

## The performance: events

Events are timed key presses, exactly like a human performing live.
Held keys need a down event AND an up event: `{"t": 1.0, "code": "KeyM",
"down": true}` … `{"t": 1.12, "code": "KeyM", "down": false}`.

| code | while held |
|---|---|
| `KeyM` | mouth open (talking) |
| `Comma` | eyes closed (blink) |
| `Slash` / `Period` | brow expressions |
| `KeyT` / `KeyB` | tilt forward / back |
| `ArrowLeft` / `ArrowRight` | walk |
| `ArrowUp` / `ArrowDown` | move deeper / closer |
| `KeyJ` | jump (tap: down then up ~0.1s later) |
| `RotateLeft` / `RotateRight` | spin |
| `ZoomIn` / `ZoomOut` | camera zoom on this character |

Other event forms, same array:

- Outfit change: `{"t": 3, "outfit": {"slot": 4, "name": "sunglasses"}}`
  (name `null` clears the slot).
- Motion params: `{"t": 5, "motion": {"speed": 400, "wobble": 10, "size": 0.62}}`
  (omit fields to leave unchanged; last-writer-wins).

**Talking that reads as speech:** alternate KeyM down/up at syllable rate
while the voice clip plays — down 60–120 ms, up 40–80 ms, roughly 4–7
cycles/sec, pausing where the audio pauses. Sprinkle a 150 ms `Comma` blink
every 2–5 s. Keep events sorted by `t`.

## Voice audio

Generate speech with any TTS, save as m4a/mp3/wav into `audio/<id>.<ext>`,
and add a clip on the speaking character:

    {"id": "line1", "name": "Coach: kickoff", "start": 1.0, "dur": 3.4,
     "offset": 0, "srcDur": 3.4,
     "fx": {"gain": 1, "low": 0, "mid": 0, "high": 0, "pan": 0, "reverb": 0}}

`dur`/`srcDur` must match the real file length. Background music goes on
`stage.audioTracks[]` (same clip shape) at low gain (~0.15–0.3).

## Backgrounds and images

Add the file to `assets/` + the `assets` bank, then cue it:

- Backdrop: `stage.backgroundTracks[].cues[]`:
  `{"id": "bg1", "assetID": "stadium", "start": 0, "dur": 30, "crop": "cover"}`
  — optional camera: `"camFrom": {"x": 0.5, "y": 0.5, "zoom": 1}` /
  `"camTo": {...}` pans/zooms over the cue.
- Overlay image (logo, pfp): `stage.imageTracks[].cues[]`:
  `{"id": "pfp1", "assetID": "fan-pfp", "start": 4, "dur": 3,
    "from": {"x": 0.8, "y": 0.25, "scale": 0.3, "rotation": 0}}`
  (optional `"to"` placement animates it).

Tracks need `{"id", "name", "cues": [...]}`; ids are any unique strings.

## Reusing characters across episodes

Keep a per-character JSON block (body, name, baseOutfit, voicePitch,
voiceSpeed, x, face) in your own notes/repo and paste it into
`stage.characters[]` each episode. Wardrobe names are stable across
app versions; re-check `banny catalog` after app updates.

## Gotchas

- Every clip/asset id in show.json needs a matching file — validate catches
  strays in both directions.
- `x` is 0..1; a character at depth > 6 is tiny. Two speakers read well at
  x 0.35 / 0.65 facing each other (face 1 / -1).
- `--480` exports fit under ~25 MB upload caps for a few minutes of show.
- Preview before ship: rendering is fast but not free; one frame tells you
  if the outfit/layout is wrong.
- The app opens `.bs` packages directly — hand the file to a human for
  finishing touches anytime.
"""#

func skillCommand(_ args: [String]) throws {
    switch args.first ?? "print" {
    case "print":
        print(skillMarkdown, terminator: "")
    case "install":
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/banny-studio")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("SKILL.md")
        try skillMarkdown.write(to: dest, atomically: true, encoding: .utf8)
        print("installed \(dest.path)")
        print("Other harnesses: `banny skill print` and save it wherever your agent reads skills.")
    default:
        throw CLIError.usage("banny skill [install|print]")
    }
}
```

- [ ] **Step 2: Wire the subcommand**

In `main.swift` add:

```swift
case "skill":
    try skillCommand(Array(args.dropFirst(2)))
```

- [ ] **Step 3: Generate the repo mirror**

```bash
mkdir -p skills/banny-studio
swift run banny skill print > skills/banny-studio/SKILL.md
```

- [ ] **Step 4: Write the mirror test**

```swift
// Tests/BannyCoreTests/SkillMirrorTests.swift
import XCTest

/// skills/banny-studio/SKILL.md must stay in lockstep with the string
/// embedded in the banny binary (Sources/banny-tool/skill.swift).
final class SkillMirrorTests: XCTestCase {
    func testRepoSkillMatchesEmbeddedSkill() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let mirror = try String(contentsOf: root.appendingPathComponent("skills/banny-studio/SKILL.md"), encoding: .utf8)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/banny-tool/skill.swift"), encoding: .utf8)
        guard let open = source.range(of: "#\"\"\"\n"),
              let close = source.range(of: "\"\"\"#") else {
            return XCTFail("raw string literal not found in skill.swift")
        }
        let embedded = String(source[open.upperBound..<close.lowerBound])
        XCTAssertEqual(mirror, embedded,
                       "regenerate with: swift run banny skill print > skills/banny-studio/SKILL.md")
    }
}
```

- [ ] **Step 5: Run tests, install locally, commit**

Run: `swift test --filter SkillMirrorTests` → PASS.
Run: `swift run banny skill install` → `installed ~/.claude/skills/banny-studio/SKILL.md`.

```bash
git add Sources/banny-tool/skill.swift skills/banny-studio/SKILL.md Tests/BannyCoreTests/SkillMirrorTests.swift Sources/banny-tool/main.swift
git commit -m "feat(cli): banny skill — embedded AI production skill + repo mirror"
```

---

### Task 7: App Help menu entry

**Files:**
- Modify: `App/Sources/BannyStudioApp.swift` (add a CommandGroup near the existing `.commands` block at line 37)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: Help → "Set up CLI & AI Skill…" menu item.

- [ ] **Step 1: Add the menu item**

Inside the existing `.commands { … }` block, after the current `CommandGroup(after: .newItem) { … }`, add:

```swift
            CommandGroup(after: .help) {
                Button("Set up CLI & AI Skill…") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/mejango/banny-studio/blob/main/skills/banny-studio/SKILL.md")!)
                }
            }
```

- [ ] **Step 2: Verify the app builds**

Run: `cd App && xcodegen && xcodebuild -project BannyStudio.xcodeproj -scheme BannyStudio -configuration Debug build -quiet && cd ..`
Expected: build succeeds. (If `xcodegen` isn't installed: `brew install xcodegen`.)

- [ ] **Step 3: Commit**

```bash
git add App/Sources/BannyStudioApp.swift
git commit -m "feat(app): Help menu link to CLI + AI skill setup"
```

Note: `App/project.yml` and `App/Info.plist` carry unrelated WIP — do not stage them.

---

### Task 8: Release script, Homebrew formula, README

**Files:**
- Create: `tools/release-cli.sh`
- Create: `tools/homebrew-banny.rb`
- Modify: `README.md` (CLI section, lines 16 and 37–39)

**Interfaces:**
- Consumes: the `banny` product from Task 5.
- Produces: a notarized zip for GitHub releases + the formula to paste into a `mejango/homebrew-banny` tap.

- [ ] **Step 1: Release script**

```bash
# tools/release-cli.sh
#!/bin/bash
# Builds, signs, notarizes, and zips the banny CLI for a GitHub release.
# Needs: DEVELOPER_ID ("Developer ID Application: …"), and notarytool
# credentials stored as keychain profile "banny-notary"
# (xcrun notarytool store-credentials banny-notary --apple-id … --team-id …).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release-cli.sh <version>}"
swift build -c release --arch arm64 --arch x86_64 --product banny
BIN=.build/apple/Products/Release/banny

codesign --force --options runtime --sign "$DEVELOPER_ID" "$BIN"
ZIP="banny-$VERSION-macos.zip"
ditto -c -k "$BIN" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile banny-notary --wait
echo "sha256: $(shasum -a 256 "$ZIP")"
echo "→ upload $ZIP to the GitHub release, update the formula sha256/version"
```

Run: `chmod +x tools/release-cli.sh` (do not run the script itself — it needs signing credentials; running it is a manual release step).

- [ ] **Step 2: Formula (tap source, kept here for copy-paste)**

```ruby
# tools/homebrew-banny.rb — copy into mejango/homebrew-banny as Formula/banny.rb
class Banny < Formula
  desc "Banny Studio CLI: author, validate, preview, and render .bs shows"
  homepage "https://github.com/mejango/banny-studio"
  url "https://github.com/mejango/banny-studio/releases/download/cli-vVERSION/banny-VERSION-macos.zip"
  sha256 "SHA256_FROM_RELEASE_SCRIPT"
  version "VERSION"

  def install
    bin.install "banny"
    bin.install_symlink "banny" => "banny-tool"
  end

  test do
    assert_match "usage: banny", shell_output("#{bin}/banny", 1)
  end
end
```

(`VERSION`/`SHA256_FROM_RELEASE_SCRIPT` are release-time substitutions made when copying into the tap — the script prints both.)

- [ ] **Step 3: README**

Update the CLI rows: line 16's table entry becomes
`| \`Sources/banny-tool\` | \`banny\` CLI: catalog, new, validate, preview, info, ship (headless mp4), stylize, skill. |`
and replace the usage block at lines 37–39 with:

```
swift run banny catalog --json                     # wardrobe options
swift run banny new show.bs --characters 2         # starter project
swift run banny validate show.bs                   # lint before shipping
swift run banny preview show.bs frame.png --t 2    # render one frame
swift run banny ship show.bs out.mp4 --720         # headless mp4 export
banny skill install                                # AI production skill → ~/.claude/skills

Install without a checkout: `brew install mejango/banny/banny`
```

- [ ] **Step 4: Full test suite + commit**

Run: `swift test`
Expected: all green.

```bash
git add tools/release-cli.sh tools/homebrew-banny.rb README.md
git commit -m "chore(cli): release script, homebrew formula, README for banny CLI"
```

---

### Task 9: End-to-end dogfood (manual gate)

**Files:** none (verification only)

- [ ] **Step 1: Fresh-eyes production run**

```bash
swift run banny skill install
swift run banny new /tmp/dogfood.bs --characters 2
# Following ONLY the installed skill text: add a 10s two-banny exchange —
# talk events + subtitles for each character (TTS audio optional).
swift run banny validate /tmp/dogfood.bs
swift run banny preview /tmp/dogfood.bs /tmp/dogfood.png --t 2
swift run banny ship /tmp/dogfood.bs /tmp/dogfood.mp4 --480
open /tmp/dogfood.mp4
```

Pass = the mp4 plays with both characters talking per the authored events and nothing in the skill text was wrong or missing. Any friction found → fix the skill text in `skill.swift`, regenerate the mirror, amend Task 6's artifacts in a follow-up commit.

---

## Self-review notes

- Spec coverage: catalog/new/validate/info/preview/ship/skill (Tasks 1–6), rename (5), Help menu (7), Homebrew + release (8), dogfood gate (9 + spec's testing section). `--sheet`, templating, TTS stay out per spec.
- The SKILL text embeds no wardrobe names except two illustrative outfit strings in examples; both are marked as needing `banny catalog` verification by the surrounding text ("Outfit names MUST come from banny catalog").
- Type consistency: `AssetCatalog.Summary` (1) is what `catalog --json` prints; `ShowLint.Diagnostic` (2) is what `validate --json` prints; `ShowDocument.starter` (3) is used by Task 4's test; `CLIError` defined once in Task 1's `assets.swift`, used in Tasks 2–6.
