import Foundation

// Embedded so the single-file release binary can install its production skill.
let skillMarkdown = #"""
---
name: banny-studio
description: Produce, edit, validate, preview, and ship Banny Studio shows with the banny CLI. Use for AI/LLM-driven Banny episodes, scenes, dialogue, TTS, lip sync, media placement, timeline performance, production automation, or safe show.json changes.
---

# Banny Studio Production

Use the `banny` CLI as the production API for Banny Studio. It creates
portable `.bs` projects that remain fully editable in the app.

## Establish the contract

Run these before authoring:

```sh
banny --version
banny capabilities --json
banny schema --example
```

Use `banny schema --compact` when exact nested fields are needed. Do not guess
field names, wardrobe names, voice IDs, media duration, or track IDs.

```sh
banny catalog --json
banny voices --json
banny info show.bs --json
```

The current editable schema is v4. Unknown JSON fields are errors. Semantic
validation also checks identities, references, ranges, package media, wardrobe,
voice recipes, mouth timing, the single Scenes track, and export readiness.

## Safe production loop

1. Create or unpack an editable folder:

   ```sh
   banny new show.bs --characters 2
   # or
   banny unpack shared.bs show.bs
   ```

2. If an existing Studio project reports schema v2 or v3, migrate it
   explicitly before editing:

   ```sh
   banny migrate show.bs --dry-run
   banny migrate show.bs
   ```

3. Inspect capabilities, schema, catalog, voices, and current show info.
4. Make structural changes with atomic RFC 6902 patches.
5. Add speech and media with their dedicated commands.
6. Run `banny validate show.bs` after every meaningful batch.
7. Preview representative moments.
8. Ship only after previews and a clean validation.
9. Pack a copy for app handoff or review.

```sh
banny preview show.bs checks/intro.png --t 2.5
banny ship show.bs episode.mp4 --1080
banny pack show.bs episode-editable.bs
```

Shipping runs the same preflight as Studio and stages output before replacing
anything. Existing output is preserved unless `--overwrite` is explicit.

## Project format

Mutation commands require an unpacked folder:

```text
show.bs/
  show.json          canonical v4 document
  audio/<clip-id>.*  portable source audio
  assets/<asset-id>.* images, animated images, and video
```

Read-only commands also accept zipped `.bs` archives. Use `unpack` before
changing one. Never mutate an archive in place.

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
Caption mode replaces prior CLI-generated `tts-*` clips for that character;
imported and microphone takes are preserved. A single `--text` appends a
speech clip and matching caption unless `--no-caption` is used.

Built-in voice recipes:

```text
natural warmNarrator tinyHero deepVillain radio robot
dream ghost alien double arcade custom
```

`--flavor` blends dry voice at 0 to the recipe at 1. Recipes are portable,
non-destructive, and use the same playback/export graph as Studio.

TTS automatically derives source-aligned `closed`, `tight`, and `open` mouth
poses from speech callbacks, text shape, and waveform energy. For an imported
or microphone take:

```sh
banny lipsync show.bs --character 1 --clip <clip-id> --json
banny lipsync show.bs --character 1 --clip <clip-id> --clear
```

Personal Voice and provider voices may appear in `banny voices`. Use only with
the speaker's authorization. Synthesized audio is baked into the project, so
playback and shipping do not depend on the voice remaining installed.

## Media

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

## Timeline vocabulary

All time values are seconds. Character indices in CLI options are one-based;
JSON arrays and JSON Pointer indices are zero-based.

Character performance events are timed key transitions:

```json
{"t":1.0,"code":"KeyM","down":true}
{"t":1.1,"code":"KeyM","down":false}
```

Codes:

```text
ArrowLeft ArrowRight       walk
ArrowUp ArrowDown          move deeper / closer
KeyT KeyB                  tilt
KeyM                       mouth override
Comma Slash Period         blink / expressions
KeyJ                       jump
KeyF KeyD                  front flip / back flip
RotateLeft RotateRight     rotate
SpinReset                  reset rotation
ZoomIn ZoomOut             animated scale
ZoomReset                  reset animated scale
```

Held actions require both down and up events. For a tap, release roughly
0.08–0.12 seconds later. Keep events sorted. Use timed motion events for
speed, rotation speed, wobble, or body-size changes, and outfit events only
with names returned by `banny catalog`.

Use named markers for points and sections for spans. Reusable multi-channel
performances belong in `stage.reactionLibrary`; place them with character
reaction blocks. Use `banny schema --compact` for their exact shape.

## Production checks

- Use stable, descriptive IDs. Never use a file path as an ID.
- Treat `--if-hash` failures as a concurrent edit; inspect again, do not force.
- Keep at least one preview per section and around every camera/media change.
- Use `--480` for fast review renders; ship the intended tier only after review.
- Never add missing media references by hand; use `banny media import`.
- Never invent voice IDs or outfit names.
- Do not use `--overwrite` until the previous deliverable is intentionally
  superseded.
- Preserve an editable packed `.bs` alongside the final mp4.

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
  short_description: "Build, inspect, validate, and ship Banny shows"
  default_prompt: "Use $banny-studio to produce or edit this Banny Studio show safely from the CLI."
"""
