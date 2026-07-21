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

`banny new` writes only `show.json` — create `audio/` and `assets/`
yourself when you add media.

`show.json` top level: `{version: 3, stage, assets, show, settings}`.
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
      "baseOutfit": {"6": "banny-vision-pro"},   // slot → outfit name, at t=0 (6 = Glasses)
      "events": [...],             // the performance (below)
      "clips": [...],              // this character's voice audio
      "subs": [{"text": "GOAL!", "start": 1.2, "dur": 2.0}],
      "voicePitch": 0, "voiceSpeed": 1
    }

Outfit names and slot numbers MUST come from `banny catalog --json`
(`slots[].outfits[].name`). Unknown names fail validate.

`banny new` seeds more fields than shown above (`armedGroups`, `presence`,
`speed`, `wobble`, `trackFx`, `hidden`, and stage-level `gScale`/`gravity`/
`gSize`/`rowOrder`). Leave them at their generated defaults — only edit the
fields documented here.

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

- Outfit change: `{"t": 3, "outfit": {"slot": 6, "name": "investor-shades"}}`
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