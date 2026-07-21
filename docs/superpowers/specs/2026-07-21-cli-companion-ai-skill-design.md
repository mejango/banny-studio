# CLI Companion + AI Production Skill — Design

**Date:** 2026-07-21
**Status:** Approved

## Goal

Any App Store user can hand their AI agent one skill file and get automated
show production: the agent authors a `.bs` project, checks its work with the
CLI, and renders mp4s headlessly. This is the loop kmac88 hand-built with
split-peel (ESPN data → script → `.bs` → render), supported out of the box.

The CLI stays thin — **introspection + render**. Authoring stays in the
agent's hands (it writes `show.json` directly). We do not build `make`-style
templating, TTS, or script generation into the CLI.

## 1. CLI surface (v1.3 of `banny-tool`)

Existing commands (`import`, `info`, `ship`, `stylize`) stay. New:

| Command | Purpose |
|---|---|
| `catalog [--json]` | Wardrobe truth from `AssetCatalog`: bodies, outfit slots/names/labels, eyes, brows, mouths, exclusivity rules. |
| `new <out.bs> [--characters N]` | Minimal valid starter project. Agents edit a known-good doc instead of authoring from a blank page. |
| `validate <show.bs> [--json]` | Decode + lint: unknown outfit names, events past content end, missing asset refs, bad clip ranges. Exit 0/1 with diagnostics. |
| `info <show.bs> [--json]` | Existing summary plus machine-readable output. |
| `preview <show.bs> <out.png> [--t SECONDS]` | Render one frame via `FrameRenderer` so agents can see before a full export. (Contact-sheet mode deferred.) |
| `ship <show.bs> <out.mp4> [--480\|--720\|--1080\|--4k] [--range A B]` | Existing, plus the 480p tier and retuned bitrates from the current export-preferences WIP. |
| `skill [install \| print]` | Writes the SKILL to `~/.claude/skills/banny-studio/SKILL.md`; `print` for other harnesses. Version-matched to the binary. |

Rename the binary to **`banny`**; keep `banny-tool` as a symlink/alias.

## 2. Distribution

- Notarized universal binary, **non-sandboxed, distributed outside MAS**.
  (MAS requires embedded executables to be sandboxed; a sandboxed CLI in its
  own container can't read arbitrary paths, which kills agent use.)
- Channels: Homebrew tap (`brew install jango/banny/banny`) + GitHub release zip.
- In-app: **Help → "Set up CLI & AI Skill…"** shows the install one-liner
  and what it unlocks. README documents the same.

## 3. The SKILL file

Source of truth: `skills/banny-studio/SKILL.md` in this repo, embedded in
the CLI binary as a resource so `banny skill install` never drifts from the
installed version.

Content:

- **Frontmatter:** name `banny-studio`; description triggers on "make/render
  a Banny show / episode / banny studio production…".
- **Setup check:** verify `banny` is on PATH; else point at the install
  one-liner.
- **The production loop:** `catalog` → `new` → edit `show.json` →
  `validate` → `preview` → `ship`. Never author from scratch; always
  validate before shipping.
- **`.bs` format guide:** directory package (`show.json` + `audio/` +
  `assets/`); document structure, tracks, event encoding (`{t, code, down}`
  performance keys — talk/tilt/jump — and `{t, outfit: {slot, name}}`
  changes, motion keyframes), audio clip fx, backgrounds/frames/camera,
  captions.
- **Recipes:** talking-head with a TTS audio file; two-character banter
  (sports-commentator pattern); reusing characters across episodes via a
  saved wardrobe+voice block per character.
- **Gotchas:** mouth/blink feel, timing against audio, aspect handling,
  export size tiers.
- Wardrobe names are **never embedded** in the skill (drift); the skill
  always says "run `banny catalog --json`".

## 4. Testing

- One CLI integration test per new subcommand against a fixture `.bs`:
  - `validate` catches a seeded error (unknown outfit name) and passes a
    clean doc.
  - `preview` writes a decodable PNG.
  - `new` → `validate` round-trips clean.
  - `catalog --json` output decodes and lists ≥1 outfit per slot.
- Skill dogfood pass (manual): fresh agent session with the skill
  installed; "make me a 10-second two-banny show" must succeed end-to-end.

## Out of scope

- `make`/templating, TTS, script drafting (agent's job).
- Contact-sheet preview (`--sheet`).
- Windows/Linux builds.
