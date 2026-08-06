---
name: banny-studio
description: Produce, edit, inspect, validate, preview, and ship editable Banny Studio shows with the banny CLI. Use for Banny scenes, episodes, social clips, dialogue/TTS, lip sync, character performance, reactions, camera, lights, visual media, audio, captions, markers, frame formats, or safe show.json automation.
---

# Banny Studio Production

Use `banny` as Banny Studio's headless production API. Prefer an installed
binary; in the source checkout, substitute `swift run banny`.

Treat the running CLI's capability contract and schema as authoritative. Never
guess a command, JSON field, enum, ID, outfit, voice, or provider capability.

## Discover the contract

Start every production or unfamiliar edit with:

```sh
banny --version
banny capabilities --json
banny help <command> --json
banny schema --example
```

Use `banny schema --compact` only when an advanced edit needs exact nested
fields. Obtain production vocabulary and current IDs instead of inventing them:

```sh
banny catalog --json
banny voices --json
banny info show.bs --json
```

The current editable schema is v4. Unknown fields are errors. Character numbers
in CLI flags are one-based; JSON array indices are zero-based.

Read only the reference needed for the current work:

- Read [references/project-format.md](references/project-format.md) before
  structural JSON Patch, migration, packing, or concurrency-sensitive edits.
- Read [references/speech-audio.md](references/speech-audio.md) before TTS,
  lip sync, imported takes, captions, or audio finishing.
- Read [references/media-stage.md](references/media-stage.md) before media
  import, camera, light, background, crop, mask, or frame-format work.
- Read [references/performance.md](references/performance.md) before adding raw
  events, reactions, wardrobe changes, motion, or start-state edits.

## Translate the brief

Resolve the duration, output shape, cast, story beats, dialogue, available
media, voice authorization, and delivery tier. Choose conservative defaults for
minor omissions. Ask only when the missing choice materially changes the work.

Plan three deliverables:

- the editable `.bs` production package;
- a packed `.bs.zip` recovery or handoff copy;
- representative review frames or a short review movie before final MP4.

## Use the safe production loop

1. Create or unpack an editable package.
2. Inspect `info`, capabilities, vocabulary, and relevant reference guidance.
3. Pack a recovery snapshot before broad changes to a valuable project.
4. Establish frame shape, named sections, export range, cast, and scene cues.
5. Prefer typed commands for common intent; use small RFC 6902 patches for
   advanced structure only.
6. Run validation after every meaningful batch.
7. Query resolved state and preview representative frames.
8. Plan the export, render short motion/audio review ranges, then ship.
9. Pack the final editable project and report its current hash.

```sh
banny new show.bs --characters 2 --json
banny validate show.bs --json
banny state show.bs --at 2.5 --json
banny preview show.bs checks/storyboard.png --times 0,2.5,5,7.5 --columns 2 --json
banny ship show.bs --plan --720 --json
banny ship show.bs checks/review.mp4 --480 --range 0 8 --progress-json --json
banny ship show.bs episode.mp4 --1080 --progress-json --json
banny pack show.bs episode-editable.bs.zip --json
```

Shipping stages its output before publishing it. Existing output is preserved
unless `--overwrite` is explicit.

## Prefer typed edits

Set a coherent recorded start state without manipulating `recStart` paths:

```sh
banny character set-start show.bs --character 1 \
  --x 0.35 --depth 0 --face right --spin 0 --zoom 1 \
  --dry-run --json
banny character set-start show.bs --character 1 \
  --x 0.35 --depth 0 --face right --if-hash <showJSONSHA256> --json
```

Add a held performance action idempotently:

```sh
banny performance add show.bs --character 1 \
  --code ArrowRight --at 1.2 --duration 0.6 \
  --if-hash <showJSONSHA256> --json
```

Both commands reject locked tracks, validate the complete proposed document,
and atomically write only `show.json`. Use `--dry-run` first and refresh the
hash between independent mutations.

## Use patches for advanced structure

Obtain the current hash with `banny info show.bs --json`, generate RFC 6902 with
a real JSON serializer, and include `test` operations for important assumptions.

```json
[
  {"op":"test","path":"/version","value":4},
  {"op":"replace","path":"/stage/characters/0/name","value":"Coach"}
]
```

```sh
banny apply show.bs change.json --dry-run --json
banny apply show.bs change.json --if-hash <showJSONSHA256> --json
```

If the hash fails, inspect again and rebase the change. Never force a stale
patch. Use `tts`, `lipsync`, and `media import` for files and references; never
fabricate package media entries by hand.

## Inspect results as an agent

Use `state` for exact simulation values and `preview --times` for visual
continuity. A still cannot prove motion or audio, so render a short 480p range
for entrances, reactions, speech, lip sync, transitions, and camera moves.

Studio's transport choices (0.5x, 1x, 1.5x, and 2x) are preview-only. They do
not retime events, change the document, or affect exported duration. Change
event/cue timing explicitly when the delivered production must run faster.

## Handoff checks

- Preserve existing IDs and update all references atomically when an ID changes.
- Respect hidden, locked, muted, solo, layer, and timed-presence state.
- Validate after structure, media, speech, performance, and mix passes.
- Keep review images for each section and around each major transition.
- Confirm rights to imported media and authorization for personal voices.
- Run `banny ship show.bs --plan --json` before a costly render.
- Do not overwrite a prior deliverable until superseding it is intentional.
- Re-run `info --json` and `validate --json` at handoff.
- Report paths, final hash, duration, frame ratio, review artifacts, and tier.

If the requested concept is absent from `capabilities --json` and the schema,
report the limitation rather than inventing syntax.
