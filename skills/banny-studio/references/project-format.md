# Project format and atomic editing

Read this before structural JSON Patch, migration, packing, or concurrent edits.

## Package layout

```text
show.bs/
  show.json          canonical v4 document
  audio/<clip-id>.*  portable source audio
  assets/<asset-id>.* images, animated images, and video
```

Use `.bs` for editable packages. Use `banny pack` to create an ordinary
`.bs.zip` handoff containing the top-level package. Read-only commands accept
packages and archives; mutation commands require an unpacked package.

The document has one continuous `stage`, not a scenes array. It contains
exactly one background track, conventionally `Scenes`; background cues are its
scene changes. `show` is the export-range array. The first valid segment wins;
leave it empty to export the whole timeline.

All times are seconds. Set `settings.frameW` and `settings.frameH` before
staging. Normalized stage coordinates use `(0,0)` at top-left and `(1,1)` at
bottom-right. Positive character depth moves farther away; negative depth moves
closer. Simulation clamps character depth to `-12...1`.

## Concurrency and recovery

Inspect immediately before writing:

```sh
banny info show.bs --json
banny validate show.bs --json
banny pack show.bs before-edit.bs.zip --json
```

Use the returned `showJSONSHA256` with mutation commands. `--if-hash` is an
optimistic concurrency guard. A mismatch means another edit won; re-read and
rebase instead of retrying blindly.

For v2/v3 projects, migrate explicitly:

```sh
banny migrate show.bs --dry-run --json
banny migrate show.bs --if-hash <showJSONSHA256> --json
```

## JSON Patch discipline

Use `apply` for shapes with no typed command. Supported operations are `add`,
`remove`, `replace`, `move`, `copy`, and `test`. Use `-` to read a patch from
stdin. The CLI applies a patch in memory, strictly decodes and validates it,
then atomically replaces `show.json`; a failure leaves the package unchanged.

Keep time-ordered arrays sorted. Preserve stable IDs. When changing an ID,
update every reference in the same patch. Do not add files or media references
through JSON Patch; use `media import`, `tts`, or `lipsync`.
