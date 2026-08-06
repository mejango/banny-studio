# Media, frame, camera, background, and lights

Read this before importing or animating visual media, changing output shape,
or editing camera and light cues.

Probe first, then import through the CLI:

```sh
banny media probe source.mov --json
banny media import show.bs source.mov --background --at 0 --json
```

The import command copies media under a unique checked ID, probes its actual
duration and dimensions, updates the right track, validates the proposal, and
rolls back the file if document publication fails.

Set frame shape before composition. `settings.frameW/frameH` may represent
16:9, 9:16, square, or custom ratios. Preview and export share the renderer.
Captions wrap and then shrink within title-safe bounds; do not hard-code line
breaks for one aspect.

Use the schema for advanced cue shapes:

- `ImageCue.from/to` interpolates position, scale, and rotation.
- `playback` trims, rates, reverses, loops, freezes, and preserves phase.
- `appearance`, `mask`, `maskRadius`, and `pivot` are non-destructive.
- `BackgroundCue.camFrom/camTo` animates the virtual camera.
- `LightCue.from/to` animates position, intensity, and physical size.

Camera focus, media, and lights use frame-normalized coordinates; entrances may
start outside the frame. Camera zoom and media scale must be positive. Light
intensity is `0...1`; light size is positive. `visualLayer` is `behindCast` or
`inFrontOfCast`.

Use adjacent cues for multi-beat paths. Preserve animated-media source phase
across splits or the source restarts. Preview the first and last frame of every
moving cue, plus camera edges, masks, character shadows, and transitions.
