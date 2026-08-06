# Character performance and reactions

Read this before editing raw character events, reactions, motion, wardrobe, or
start state.

Prefer typed start-state and event commands. Use raw JSON only for motion,
outfit, or reaction structures not yet exposed by a typed command.

Event codes:

```text
ArrowLeft ArrowRight       walk
ArrowUp ArrowDown          depth
KeyT KeyB                  tilt
KeyM                       manual mouth
Comma Slash Period         blink / brow 1 / brow 2
KeyJ                       jump
KeyF KeyD                  front flip / back flip
RotateLeft RotateRight     free rotation
SpinReset                  reset rotation
ZoomIn ZoomOut             animated character scale
ZoomReset                  reset animated scale
```

Held actions need down and up events. A tap is usually 0.08–0.12 seconds. Keep
events sorted. Obtain the exact vocabulary from `capabilities --json`.

Use `character set-start` to update base `x/depth/face/size` together with the
recorded start pose. A non-null `recStart` seeds simulation position, facing,
spin, and zoom; hand-editing only the base can create a stale mismatch.

Use timed motion events for speed, rotation speed, wobble, or size changes. Use
outfit names returned by `catalog --json`. Preview wardrobe dissolves around
the exact event time.

Jump and flips are gravity-driven. Leave `rotationPivot` null for automatic
feet/body-center behavior unless a deliberate normalized pivot is required.

Store reusable multi-channel performances in `stage.reactionLibrary`, then
place character reaction blocks. Definition times are local; block `dur`
stretches tempo and `intensity` scales continuous motion. Avoid overlapping
reactions that own the same channel unless the composite has been reviewed.

Use named markers and sections before dense performance editing. Avoid
overlapping spoken captions unless simultaneous speech is intentional.
