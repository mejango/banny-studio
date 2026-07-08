# Banny Studio — Native Universal App Design

Date: 2026-07-07
Status: Approved by jango
Source app: `/Users/jango/Documents/banny/playground/index.html` (single-file web studio, v1)

## Goal

Full native rewrite of the Banny Studio webapp as **one universal SwiftUI app** for
macOS (primary creator surface), iPadOS (full studio, touch + Apple Pencil), and
iOS (adapted studio + viewer). App Store distribution, universal purchase.
Sync across a user's devices and sharing with other users via iCloud — no servers.

The rewrite preserves the webapp's functionality exactly (feature inventory below),
refines the internals, and establishes a foundation for future show-making features.

## Decisions (locked)

| Decision | Choice |
|---|---|
| Architecture | Full native rewrite (no WKWebView) |
| Rendering | Deterministic core: pure `draw(t)` compositor, parts baked to images at build time, SwiftUI `Canvas` / CoreGraphics |
| Storage/sync | `.bannyshow` document packages on iCloud Drive; document-based SwiftUI app |
| Sharing | System iCloud document collaboration + share sheet; rendered mp4s share anywhere |
| Packaging | One universal app target, one listing, universal purchase |
| Touch puppeteering | Performance deck (thumbstick + hold-button cluster), game-controller layout |
| Legacy files | One-way importer for web v1 JSON (staging/exports format) |
| Min targets | macOS 14, iOS/iPadOS 17 |
| Pricing | Free at launch |
| Deferred | AI background prompt (`SCENE_PROMPT`), web-format export |

## Architecture

Three layers:

1. **`BannyCore`** (SwiftPM package, platform-free, no UI)
   - Document model (schema v2), Codable types
   - Event/performance types: 6 groups (move, depth, tilt, talk, blink, jump) + timed outfit changes
   - `SceneSimulator`: state as a **pure function of (document, time)** — fixed 1/60 s
     integration step, replicating web `advancePos`/`simulatePos`/`resetToTime` math
   - Asset catalog metadata (slots, exclusivity rules, options)
   - Legacy v1 JSON importer (base64 audio → m4a files)
2. **`BannyRender`** (SwiftPM package)
   - Pure frame compositor: `(SceneState, assets, size) → CGContext` drawing
   - Order: background (cover/fit/stretch/tile) → sun shadows → characters
     back-to-front by depth (translate/scale/flipX/rotate) → captions
   - Used identically by the live editor view and the exporter
3. **App target** (SwiftUI, multiplatform)
   - DocumentGroup + library browser (thumbnail grid) home
   - Stage view (Canvas), scene tabs, timeline, wardrobe/inspector, performance deck
   - Audio engine, exporter, share/collaboration UI

## Document format — `.bannyshow` package

```
MyShow.bannyshow/
  show.json          — schema v2 (below)
  audio/<clipId>.m4a — audio sources as files
  bg/<sceneId>.*     — background media (png/jpg/gif/svg/mp4)
  thumbnail.png
```

`show.json` (v2) carries the same concepts as web v1 with cleaned names:

- `scenes[]`: id, name, state
  - state: `characters[]` (body, x 0..1, depth −12..1, size, face ±1, baseOutfit,
    subs[], clips[], events[], armedGroups[], name, trackFx, recStart),
    `audioTracks[]`, `lights[] {x,y}`, `cropAnchors[]` (sec), `gScale`, `gravity`,
    `gSize`, selection flags
- `show[]`: playlist segments `{sceneId, name, from, to}`
- `settings`: active scene, lightSize
- Events: `{t, code, phase: down|up}` and `{t, outfit: {slot, name?}}`
- Audio clips: `{id, name, start, dur, offset, srcDur, fx {gain, low, mid, high, pan, reverb}}`
  - pan ∈ follow | narrow | wide | numeric −1..1

Legacy importer maps web v1 (`{studio, bg, audio}` with base64 data URLs) 1:1 into
this package. Undo = per-document `UndoManager`; autosave = document system.

## Simulation & rendering

- **Determinism rule:** live playback, scrubbing, recording playback, and export all
  derive stage state from `SceneSimulator.state(at: t)`. Recording appends events;
  nothing else mutates mid-playback state.
- Motion math carried over exactly: `|sin|` two-bounce gait (phase += dt·speed/22,
  bob = −|sin φ|·wobble, sway = sin φ·2.5), jump parabola (dur 460/gravity ms,
  height 30/gravity), tilt ±9°, depth rate (speed/320)·0.36/max(gScale,0.1),
  scale = size·gSize·(1−depth·gScale)·(H/900), edge margin max(10, W·0.044),
  z-order round((2−depth)·100), stage aspect (16/9)·(1−0.038) with the bottom strip
  excluded from the 16:9 content/export region.
- **Asset bake:** build-time macOS tool rasterizes each SVG part (4 bodies, 6 eye
  sets with blink frames, 4 mouths with open/tight/closed, 52 outfit parts, shadow,
  sun) at 4× into an asset catalog. Pixel art; nearest-neighbor scaling. Slot
  render order [2, BODY, 3, 4, EYES, 6, MOUTH, 8, 9, 10, 11, 12, 13]; exclusivity:
  Head(4) hides Glasses(6)+HeadTop(12); Suit(9) hides SuitBottom(10)+SuitTop(11).
  Max 10 characters per scene.

## Editor UX

- **Mac:** stage center, scene tabs top, resizable timeline bottom, wardrobe/
  inspector right. Identical keyboard puppeteering (←→ walk/turn, ↑↓ depth,
  `,` `/` `.` blinks, M talk, T/B tilt, J jump, digits select, Shift+digit
  multi-select, Space play, ⇧Space record, ⌘Z undo, ⌘C/⌘V marks, Del delete).
  Menu bar + shortcuts. Timeline is a custom Canvas: ruler, scrub bar, crop bar
  with draggable anchors → segments → Show playlist, per-track lanes with
  performance marks (7 sub-lanes, group colors), audio clips with waveforms,
  captions; box-select, drag-move, edge-resize, ⌘-drag duplicate, ⌘-click split,
  paste-at-playhead, nudge ±0.1/±0.5; zoom 1–16×; per-track arm dots, set-start,
  ground, track fx.
- **iPad:** same regions, touch-sized. Performance deck: left thumbstick =
  walk/depth; right hold-button cluster = talk, blink×3, tilt×2, jump; character
  chips to retarget. Pencil scrubs and does precision drags. Hardware keyboard
  behaves like Mac.
- **iPhone:** same document, mode switcher — Watch (library + player), Stage
  (landscape deck recording), Timeline (arrange/trim), Wardrobe. Nothing removed
  that fits; deep multi-panel work naturally lives on Mac/iPad.

## Audio

`AVAudioEngine`: per-clip player → 3-band EQ → pan → owner track bus
(gain/EQ/reverb send) → main mix. Reverb = synthetic IR ≈ web's 1.6 s impulse.
Pan follow = subtle L/R from character X (·0.3), narrow = center, wide = edges.
Waveform peaks decoded once, cached. Clip drop-in/split/trim/offset carried over.
New in v1: record voice directly via microphone onto a track.

## Export ("Ship")

Offline and deterministic (replaces MediaRecorder capture):
- Video: iterate show playlist segments (or active scene if playlist empty),
  render `draw(t)` frames at 30 fps into `AVAssetWriter`. H.264 mp4.
  Default 1080p; 720p/4K options.
- Audio: `AVAudioEngine` manual-rendering mode bounces the same mix → AAC, muxed.
- Faster than realtime, no dropped frames, background-safe. Output to share sheet.

## Sync, sharing, App Store

- iCloud Drive syncs `.bannyshow` documents across the user's devices (ubiquity
  container, `NSDocument`/`UIDocument` via SwiftUI DocumentGroup).
- Share a show: system collaboration (co-access) or Send Copy. Rendered videos
  share anywhere.
- Entitlements: iCloud Documents, ubiquity container. No push, no CloudKit custom
  DB, no accounts.
- One listing; review notes explain it's an original content-creation tool.

## Testing

- `BannyCore` unit tests: simulator golden tests replaying ep1's real event
  streams (923 events) asserting sampled positions/state; importer round-trip
  against `show/ep1/beat1/staging/1.json`.
- `BannyRender` snapshot tests vs reference PNGs.
- Export test: frame count/duration checksums on a fixture show.
- Thin XCUI smoke: open → record 2 s → ship.

## Build phases

1. `BannyCore` + legacy importer + simulator (headless, ep1-tested)
2. Asset bake tool + `BannyRender` (scene renders)
3. Mac editor: stage, keyboard puppeteering, timeline, record
4. Audio engine + export → Mac feature-complete
5. iPad layout + performance deck + Pencil
6. iPhone modes + polish
7. App Store packaging (icons, entitlements, TestFlight)
