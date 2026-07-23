# Banny Studio — native universal app

Full native rewrite of the Banny playground web studio (`playground/index.html`)
as one SwiftUI app for **macOS + iPadOS + iOS**. Same show-making functionality,
deterministic to the pixel, App Store-ready structure.

Spec: `docs/superpowers/specs/2026-07-07-banny-studio-native-design.md`

## Layout

| Path | What |
|------|------|
| `Sources/BannyCore` | Strict document model (schema v4), event semantics, deterministic simulator, legacy v1 importer, and portable show package I/O. Platform-free. |
| `Sources/BannyRender` | Baked-asset catalog + pure `draw(t)` CoreGraphics frame compositor. Same code path for editor and export. |
| `Sources/BannyMedia` | Audio graph, TTS/lip-sync production, media probing, preview, and offline H.264/AAC export. |
| `Sources/BannyCLI` | Testable production API for strict JSON Patch, speech, media, validation, previews, packaging, and shipping. |
| `Sources/banny-tool` | Thin `banny` executable entry point around `BannyCLI`. |
| `App/` | The universal SwiftUI app (XcodeGen project). Editor, timeline, wardrobe, performance deck, Ship. |
| `App/Resources/BannyAssets` | Extracted + baked art (catalog.json, png/, svg/). |
| `tools/` | `extract-assets.mjs` (pull art constants from index.html), `bake-assets.sh` (rasterize via headless Chrome), `gen-golden.mjs` (golden sim fixtures from the ORIGINAL JS math). |

## Build

```sh
swift test                        # unit/golden/snapshot tests
cd App && xcodegen generate       # brew install xcodegen (once)
xcodebuild -project BannyStudio.xcodeproj -scheme BannyStudio \
  -destination 'platform=macOS' build          # or open in Xcode and Run
```

iOS: same scheme, destination `platform=iOS Simulator,name=iPhone 16 Pro`.
UI smoke test: `xcodebuild … test` (on macOS it needs a one-time automation
permission grant; on the iOS simulator it runs unattended).

## CLI

```sh
swift run banny capabilities --json                    # machine contract
swift run banny schema --example                       # canonical v4 example
swift run banny catalog --json                         # wardrobe vocabulary
swift run banny voices --json                          # installed TTS voices
swift run banny new show.bs --characters 2             # editable folder
swift run banny migrate legacy-show.bs --dry-run        # explicit v2/v3 → v4
swift run banny apply show.bs patch.json --dry-run     # atomic RFC 6902
swift run banny tts show.bs --character 1 --captions   # speech + mouth cues
swift run banny media import show.bs take.wav \
  --character 1 --kind microphone --lipsync            # portable recorded take
swift run banny validate show.bs                       # strict preflight
swift run banny preview show.bs frame.png --t 2        # deterministic frame
swift run banny ship show.bs out.mp4 --720             # headless mp4 export
swift run banny pack show.bs shareable.bs              # zipped app handoff
banny skill install --target all                       # Codex + Claude skill
```

Read-only commands accept editable folders and zipped `.bs` archives. Mutation
commands require an unpacked folder and reject unknown options and JSON fields.
Use `banny capabilities --json` as the exact AI/automation contract.

Install without a checkout: `brew install mejango/banny/banny`.

`ep1-native-ship.mp4` in this folder is ep1 shipped natively (160.9 s,
1280×720@30, H.264+AAC) from `show/ep1/beat1/staging/1.json`.

## Determinism (the load-bearing idea)

Stage state is a **pure function of (document, time)**: fixed 1/60 s integration,
exact partial final step, identical math in live playback, scrubbing, and export.
`tools/gen-golden.mjs` runs the *original webapp JS* on real ep1 event streams;
Swift tests assert the port matches to 1e-9. Never break these tests.

## Asset pipeline (regenerate when the web art changes)

```sh
node tools/extract-assets.mjs [path/to/index.html]
./tools/bake-assets.sh          # needs Google Chrome installed
```

## Remaining owner actions (can't be automated)

1. **iCloud sync**: accept the latest Apple Developer Program License Agreement
   at developer.apple.com, then uncomment the iCloud entitlement block in
   `App/project.yml`, `xcodegen generate`, rebuild. Documents then live in
   iCloud Drive and sync/share across devices (system collaboration).
2. **App Store**: create the app record in App Store Connect
   (bundle id `com.banny.BannyStudio`), archive in Xcode (Product → Archive)
   for macOS and iOS, upload, TestFlight.
3. First local run: `open App/BannyStudio.xcodeproj`, select the BannyStudio
   scheme, Run. File → Import Web Studio JSON… converts old staging files.

## Known gaps vs the webapp (tracked, not blockers)

- Timeline box-select (rubber band) not yet wired; single/⇧ selection, drag,
  edge-resize, ⌘-click split, ⌘C/⌘V, and delete all work.
- Editor previews video backgrounds at ~7 fps (export samples exact frames).
- No in-app player/library screen yet; watching = Ship or QuickTime.
- Scene-preset backgrounds (web SCENES) were empty in the source build — n/a.
