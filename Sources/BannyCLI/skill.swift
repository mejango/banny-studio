import Foundation

// Embedded so the single-file release binary can install its production skill.
let skillMarkdown = #"""
---
name: banny-studio
description: Produce, edit, inspect, validate, preview, and ship editable Banny Studio shows with the banny CLI. Use when an AI/LLM needs to create or revise Banny episodes, scenes, social clips, dialogue/TTS, lip sync, character performance, reactions, camera, lights, visual media, audio mixes, captions, markers/sections, frame formats, or safe show.json automation.
---

# Banny Studio Production

Use the `banny` CLI as the production API for Banny Studio. It creates
portable `.bs` projects that remain fully editable in the app. Prefer an
installed `banny`; inside the source checkout, substitute `swift run banny`.

Treat the running binary's capability contract and schema as authoritative if
they differ from this prose. Never emulate a missing command by guessing JSON.

## Translate the brief

Before editing, resolve the intended duration, output shape, cast, story beats,
dialogue, available media, voice authorization, and delivery tier. If the user
leaves one unspecified, choose a conservative default and state it. Turn the
brief into a timing map with named sections before adding detailed performance.

Plan for three deliverables:

- the editable `.bs` package used during production;
- a packed `.bs.zip` recovery/handoff copy;
- review frames or a short review movie before the final MP4.

## Establish the contract

Run these before authoring:

```sh
banny --version
banny capabilities --json
banny schema --example
```

Use `banny schema --compact` when exact nested fields are needed. Do not guess
field names, wardrobe names, voice IDs, media duration, cue IDs, or track IDs.

```sh
banny catalog --json
banny voices --json
banny info show.bs --json
```

For an editable project, inspect `show.bs/show.json` after `info` to obtain
existing IDs and values. Re-run `info` immediately before mutation; its
`showJSONSHA256` is the optimistic-concurrency token.

The current editable schema is v4. Unknown JSON fields are errors. Semantic
validation also checks identities, references, ranges, package media, wardrobe,
voice recipes, mouth timing, the single Scenes track, and export readiness.

## Safe production loop

1. Create or unpack an editable package:

   ```sh
   banny new show.bs --characters 2
   # or
   banny unpack shared.bs.zip show.bs
   ```

2. If an existing Studio project reports schema v2 or v3, migrate it
   explicitly before editing:

   ```sh
   banny migrate show.bs --dry-run
   banny migrate show.bs
   ```

3. For a valuable existing project, pack a recovery snapshot before broad edits:

   ```sh
   banny pack show.bs show-before-ai-edit.bs.zip
   ```

4. Inspect capabilities, schema, catalog, voices, current IDs, and the current
   hash.
5. Establish frame format, named sections, export range, cast, and scene cues.
6. Make structural changes with small atomic RFC 6902 patches.
7. Add media, speech, and lip sync with their dedicated commands.
8. Add performance, reactions, camera/light motion, and audio finishing.
9. Run `banny validate show.bs` after every meaningful batch.
10. Preview representative frames and render short motion/audio review ranges.
11. Ship only after review and a clean validation, then pack the editable copy.

```sh
mkdir -p checks
banny preview show.bs checks/intro.png --t 2.5
banny ship show.bs checks/intro-review.mp4 --480 --range 0 8
banny ship show.bs episode.mp4 --1080
banny pack show.bs episode-editable.bs.zip
```

Shipping runs the same preflight as Studio and stages output before replacing
anything. Existing output is preserved unless `--overwrite` is explicit.

## Project format

Mutation commands require an unpacked `.bs` package:

```text
show.bs/
  show.json          canonical v4 document
  audio/<clip-id>.*  portable source audio
  assets/<asset-id>.* images, animated images, and video
```

Use `.bs` for every editable package. Finder presents the package directory as
one document. `banny pack` writes an ordinary `.bs.zip` that contains the
top-level `.bs`, so standard ZIP expansion produces an editable project.

Read-only commands also accept `.bs.zip` archives. Legacy `.bannyshow`
packages and zipped `.bs` handoffs remain readable for migration. Use `unpack`
before changing an archive, and never mutate an archive in place.

The document has one continuous `stage`, not a scenes array. It must contain
exactly one background track, conventionally named `Scenes`; its background
cues are the production's scene changes. Other track types are character,
audio/media, image, and light.

All time values are seconds. CLI character numbers are one-based; JSON arrays
and JSON Pointer indices are zero-based. Stage `x/y` positions are normalized
to the active output frame: `(0,0)` is top-left and `(1,1)` is bottom-right.
Media, light, and camera positions may intentionally go outside that range for
entrances; character walking is clamped near the stage edges. Pivots must
remain inside `0...1`.

Set output shape with `settings.frameW` and `settings.frameH` before staging.
Studio preview, still preview, and export share the same renderer. Captions
wrap first, then shrink inside the active frame's title-safe area, so keep each
caption to one readable thought and do not hard-code line breaks for one aspect.

`show` is the persistent export-range array; the first valid item is used.
Leave it empty to ship the whole timeline. `banny ship --range FROM TO`
temporarily overrides it without changing the project.

Respect `hidden`, `locked`, `solo`, and timed `presence` state. Treat a locked
track as read-only unless the user explicitly asks to unlock or replace it.
Avoid editing the same project simultaneously in Studio and the CLI.

## Atomic JSON changes

Prefer a small JSON Patch to rewriting `show.json`. Obtain the current hash:

```sh
banny info show.bs --json
```

Create a patch:

```json
[
  {"op":"test","path":"/version","value":4},
  {"op":"replace","path":"/stage/characters/0/name","value":"Coach"},
  {"op":"add","path":"/stage/markers/-","value":{
    "id":"intro","name":"Intro","start":0,
    "kind":"section","duration":8,"color":"blue"
  }}
]
```

Dry-run, then apply with optimistic concurrency:

```sh
banny apply show.bs change.json --dry-run --json
banny apply show.bs change.json --if-hash <showJSONSHA256> --json
```

Supported operations are `add`, `remove`, `replace`, `move`, `copy`, and
`test`. A patch is applied in memory, strictly decoded, semantically validated,
then written atomically. Any failure leaves `show.json` untouched. Use `-` as
the patch path to read JSON Patch from stdin.

Include `test` operations for assumptions that matter, not only the schema
version. Generate JSON with a real serializer, keep time-ordered arrays sorted,
and dry-run each independent batch. If `--if-hash` fails, discard the stale
patch context, inspect the project again, and rebase the change.

Use patches for document structure and timing. Use `tts`, `lipsync`, and
`media import` for generated/copied files and their references; never fabricate
package media entries or orphan files by hand.

## Speech, voices, and mouth timing

List exact installed IDs:

```sh
banny voices --language en --json
```

Generate one line:

```sh
banny tts show.bs \
  --character 1 \
  --text "Welcome to the show." \
  --at 1.2 \
  --voice com.apple.voice.compact.en-US.Samantha \
  --preset warmNarrator \
  --flavor 0.65 \
  --json
```

Generate every nonempty caption already on the character:

```sh
banny tts show.bs --character 1 --captions --voice <id> --json
```

Without `--text`, `--text-file`, or `--captions`, caption mode is the default.
Caption mode uses each caption's own start time and replaces prior
CLI-generated `tts-*`/legacy `ani-*` clips for that character; imported and
microphone takes are preserved. A single `--text` or `--text-file` starts at
`--at`, appends a speech clip and matching caption, and leaves other generated
clips alone unless `--replace-generated` is present. Use `--no-caption` only
when visible captions are intentionally unwanted.

Caption mode preserves existing caption durations. After synthesis, compare
the JSON-reported clip durations with `subs`; keep each caption visible through
its speech and leave readable gaps. Regenerate caption speech after changing
caption text or start times.

Use `--rate 0...1` and `--pitch 0.5...2` for source synthesis. Use
`--preset` and `--flavor 0...1` for the editable post-processing recipe. Clip
edges default to short fades; override them with nonnegative
`--fade-in SECONDS` and `--fade-out SECONDS`. Use `--no-lipsync` only when
mouth automation is intentionally disabled.

Built-in voice recipes:

```text
natural warmNarrator tinyHero deepVillain radio robot
dream ghost alien double arcade custom
```

`--flavor` blends dry voice at 0 to the recipe at 1. Recipes are portable,
non-destructive, and use the same playback/export graph as Studio. The custom
recipe schema also exposes pitch, three-band EQ, compression, distortion,
delay, doubling, reverb, and output gain; obtain every supported range from
`banny schema --compact`.

TTS automatically derives source-aligned virtual `KeyM` press intervals from
speech callbacks and waveform energy. Automatic mouth is binary: every visible
cue is the same ordinary M-down/open-mouth state, silence is M-up/closed, and a
manually held M temporarily wins. Do not design separate pixel or phoneme mouth
poses. Keep `speechVoice.automaticMouth` enabled, use the generated timing, then
nudge, resize, split, or delete intervals in Studio when needed.

For an imported or microphone take:

```sh
banny lipsync show.bs --character 1 --clip <clip-id> --json
banny lipsync show.bs --character 1 --clip <clip-id> --clear
```

Personal Voice and provider voices may appear in `banny voices`. Use only with
the speaker's authorization. Synthesized audio is baked into the project, so
playback and shipping do not depend on the voice remaining installed.

### Audio finishing

Use character `trackFx` and audio-track `fx` for the bus mix. Use clip `fx`,
`fxOverride`, `fadeIn`, and `fadeOut` for exceptions. Gain is linear, EQ values
are dB, reverb is `0...1`, and pan is `follow`, `narrow`, `wide`, or a fixed
`-1...1`; confirm exact ranges in the schema. `follow` tracks a character's
on-screen X position. Speech recipes process only speech clips, while imported
and microphone clips remain dry apart from their normal clip/track mix. A peak
limiter protects the shared master in playback and export.

Review speech intelligibility, clip edges, overlaps, pan, and the loudest
section in a short MP4. Do not rely on the limiter to repair an overloaded mix.

## Media, camera, and lights

Probe before placing media:

```sh
banny media probe source.mov --json
```

Import a backdrop:

```sh
banny media import show.bs stadium.gif \
  --id stadium \
  --name "Stadium" \
  --background \
  --at 0 \
  --duration 12 \
  --crop cover \
  --json
```

Import a floating visual:

```sh
banny media import show.bs logo.png \
  --track <image-track-id> \
  --at 4 --duration 3 \
  --x 0.8 --y 0.2 --scale 0.25 --rotation 0 \
  --json
```

Import dialogue or a microphone recording:

```sh
banny media import show.bs take.wav \
  --character 1 \
  --at 6 \
  --kind microphone \
  --lipsync \
  --json
```

The import command copies media under a unique checked ID, probes real duration
and dimensions, updates the correct track, validates the proposed project, and
rolls back its new file if the document write fails. Omit `--track` to create
or use an appropriate default track.

After import, use the schema and atomic patches for advanced cue behavior:

- `ImageCue.from` and `to` linearly animate position, scale, and rotation.
- `playback` trims, changes rate/direction, loops, freezes, and preserves phase.
- `appearance`, `mask`, `maskRadius`, and `pivot` provide non-destructive looks.
- `BackgroundCue.camFrom` and `camTo` animate the virtual camera.
- `LightCue.from` and `to` animate position, intensity, and physical size.

Use multiple adjacent cues for a multi-beat motion path. For an animated
visual continuation, preserve source phase by adding
`elapsed * playback.rate` to `playback.phaseOffset`; otherwise the GIF/video
restarts at the split. Prefer Studio's drag recorder for subjective paths, then
inspect and validate the resulting cues.

Camera focus `(x,y)` and media/light positions use frame-normalized
coordinates. Camera `zoom` and media `scale` must stay positive. Light
intensity is `0...1`; light size must be positive. Preview camera edges, masks,
character shadows, flips, and the first/last frame of every moving cue.

## Timeline vocabulary

Character performance events are timed key transitions:

```json
{"t":1.0,"code":"KeyM","down":true}
{"t":1.1,"code":"KeyM","down":false}
```

Codes:

```text
ArrowLeft ArrowRight       walk
ArrowUp ArrowDown          move deeper / closer in frame
KeyT KeyB                  tilt pair
KeyM                       mouth override
Comma Slash Period         blink / brow 1 / brow 2
KeyJ                       jump
KeyF KeyD                  front flip / back flip
RotateLeft RotateRight     rotate left / right
SpinReset                  reset rotation
ZoomIn ZoomOut             zoom character in / out
ZoomReset                  reset animated scale
```

Held actions require both down and up events. For a tap, release roughly
0.08–0.12 seconds later. Keep events sorted. Use timed motion events for
speed, rotation speed, wobble, or body-size changes, and outfit events only
with names returned by `banny catalog`.

In Studio, a stopped Scenes track leaves scene controls selected while the
performance keys preview the most recently selected character. Starting REC
keeps Scenes as the target and switches arrows/zoom to camera recording.

Use base `x`, `depth`, `face`, and `size` for the initial character state. A
non-null `recStart` overrides the initial `x/depth/face` used by simulation and
also seeds rotation and zoom, so update or remove stale `recStart` whenever the
base pose changes. Positive depth moves farther/smaller and negative depth
moves closer/larger; simulation clamps it to `-12...1`.

`KeyJ`, `KeyF`, and `KeyD` are gravity-driven actions. `stage.gravity` changes
their duration, arc, and landing weight. Leave `rotationPivot` null for the
recommended automatic behavior—feet for grounded rotation and body center for
flips—or set a normalized pivot deliberately and preview its shadow throughout
the flip.

Use named markers for points and sections for spans. Lay down sections before
dense events so the timing remains auditable. Avoid overlapping spoken
captions unless two characters are intentionally speaking together.

Put reusable multi-channel performances in `stage.reactionLibrary` and place
them with character reaction blocks. Definition event times are local to the
reaction; a block stretches tempo with `dur` and scales continuous motion with
`intensity`. Avoid overlapping reactions that own the same channels unless the
result has been previewed. Use `banny schema --compact` for exact shapes.

## Production checks

- Use stable, descriptive IDs. Never use a file path as an ID.
- Preserve existing IDs when revising; changing an ID requires updating every
  reference in the same atomic patch.
- Treat `--if-hash` failures as a concurrent edit; inspect again, do not force.
- Validate after structure, media, dialogue, performance, and mix passes.
- Keep at least one preview per section and around every cut, camera/media
  change, caption-density change, reaction, and light transition.
- Use short `--480 --range FROM TO` renders to judge motion, speech, lip sync,
  transitions, and audio; still previews cannot verify time.
- Use `--480` for fast review renders; ship the intended tier only after review.
- Never add missing media references by hand; use `banny media import`.
- Never hand-author generated audio or mouth cues when `tts` or `lipsync` can
  produce them.
- Never invent voice IDs, outfit names, enum values, or provider capabilities.
- Confirm the user has rights to imported media and authorization for Personal
  Voice or third-party installed voices.
- Do not use `--overwrite` until the previous deliverable is intentionally
  superseded.
- Preserve an editable packed `.bs` alongside the final mp4.
- Re-run `banny info --json` and `banny validate --json` at handoff, and report
  the final hash, duration, frame ratio, review artifacts, and output paths.

If a requested concept is not represented in `banny capabilities --json` or
`banny schema --compact`, report that limitation instead of inventing syntax.

"""#

func skillCommand(_ args: [String]) throws {
    let action = args.first ?? "print"
    var options = CLIOptions(args.isEmpty ? [] : Array(args.dropFirst()))
    switch action {
    case "print":
        try options.finish(usage: "banny skill print")
        print(skillMarkdown, terminator: "")
    case "install":
        let target = try options.value("--target") ?? "all"
        try options.finish(
            usage: "banny skill install [--target codex|claude|all]")
        guard ["codex", "claude", "all"].contains(target) else {
            throw CLIError.invalid("--target must be codex, claude, or all")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var destinations: [(url: URL, codex: Bool)] = []
        if target == "claude" || target == "all" {
            destinations.append((
                home.appendingPathComponent(".claude/skills/banny-studio"),
                false))
        }
        if target == "codex" || target == "all" {
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                .map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            destinations.append((
                codexHome.appendingPathComponent("skills/banny-studio"),
                true))
        }
        for destination in destinations {
            try FileManager.default.createDirectory(
                at: destination.url, withIntermediateDirectories: true)
            try skillMarkdown.write(
                to: destination.url.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8)
            if destination.codex {
                let agents = destination.url.appendingPathComponent("agents")
                try FileManager.default.createDirectory(
                    at: agents, withIntermediateDirectories: true)
                try skillOpenAIYAML.write(
                    to: agents.appendingPathComponent("openai.yaml"),
                    atomically: true,
                    encoding: .utf8)
            }
            print("installed \(destination.url.path)")
        }
    default:
        throw CLIError.usage(
            "banny skill [print|install] [--target codex|claude|all]")
    }
}

private let skillOpenAIYAML = """
interface:
  display_name: "Banny Studio Production"
  short_description: "Produce polished, editable Banny Studio shows"
  default_prompt: "Use $banny-studio to turn this brief into a validated, previewed, editable Banny Studio production."
"""
