# Banny Live rooms

Banny Live is a browser-playable room runtime around Studio's canonical v4
`.bs` format. One macOS host owns admission, the scene clock, autonomous
character decisions, rendering, and the editable recording. Once that host is
available through public HTTPS, a creator, player, or viewer needs only an
ordinary browser and an Internet connection.

```text
creator / player / viewer browser ── HTTPS ──→ Banny Live host
                                               ├─ host-wide director
                                               │    ├─ built-in
                                               │    └─ loopback Ollama
                                               ├─ Banny renderer + JPEG stage
                                               ├─ creator's MP3 only
                                               └─ editable recording.bs
```

The browser never connects to Ollama. The host is the only process that calls
the configured director, and the Ollama option accepts only a numeric-loopback
HTTP origin.

## Current scope

- Public rooms or capability-based allowlists.
- One to ten reserved character seats, matching Studio's tested cast limit.
- One uploaded image, animated image, or video background, plus one MP3.
- Optional subtle motion for still images: sparse point lights use the same
  `ShimmerEncoder` as `banny shimmer`, with a gentle camera-drift fallback.
- Built-in Banny bodies, face options, wardrobe, accessories, and props.
- Direct browser join with a dressed character and a private prompt.
- One host-wide autonomous director: deterministic built-in behavior by
  default, or a host-local Ollama model.
- Server-authoritative, bounded caption and action intents.
- Native Banny frame rendering and a continuously updated strict v4 `.bs`
  recording.
- Exactly one audible source: the creator-supplied background MP3. Character
  dialogue is transcript/caption text plus visual mouth motion only.

Uploads are decoded and staged under fixed budgets: 70 MiB combined media,
16 Mi-pixels per background frame, 600 animated-image frames, and 64 Mi-pixels
across an animated image. Larger moving sets should use video. Custom
`.bannyoutfit` artwork is not portable through the headless package loader yet,
so room avatars use built-in catalog art in this release.

## Quickstart with the built-in director

Start the room host:

```sh
swift run banny room serve \
  --storage ./live-rooms \
  --bind 127.0.0.1 \
  --port 7330
```

Open `http://127.0.0.1:7330/create`. Supply a title, optional premise, one
background image/video, one MP3, occupancy from 1 through 10, and optionally
one allowlist identity per line. Still images can use subtle animation; video
and animated-image sources retain their own motion.

Creation returns the host capability and one identity-bound invite for every
allowlist entry. They are shown only to the creating browser. Share each invite
through a private channel and keep the control tab available for kick/end
operations.

The recording package exists before the room is published:

```text
live-rooms/<room-id>/recording.bs/
  show.json
  assets/room-background.*
  audio/room-music.mp3
```

## Use Ollama on an M1 Mac

Ollama supports Apple M-series Macs through Metal. Follow its
[macOS installation guide](https://docs.ollama.com/macos), launch the app, and
make sure its `ollama` command is on `PATH`. Pull the default Banny model once:

```sh
ollama pull llama3.2:3b
```

The macOS app normally starts the local API. If it is not already running,
start it in a dedicated terminal:

```sh
ollama serve
```

Then start Banny with the Ollama director:

```sh
swift run banny room serve \
  --storage ./live-rooms \
  --bind 127.0.0.1 \
  --port 7330 \
  --director ollama \
  --director-url http://127.0.0.1:11434 \
  --director-model llama3.2:3b
```

`--director-url` and `--director-model` are valid only with
`--director ollama`. Banny requires an `http://` numeric-loopback origin such
as `127.0.0.1` or `[::1]`; it rejects `localhost`, LAN/public hosts, HTTPS,
credentials, paths, queries, fragments, and redirects. Do not expose Ollama to
the Internet.

For every turn, Banny posts to `/api/chat` with the selected model,
`stream: false`, and JSON output. Requests, responses, and deadlines are
bounded. The model may return only this smaller shape:

```json
{
  "say": "Is this seat taken?",
  "actions": [
    {"op": "tilt", "direction": "forward", "duration_ms": 500}
  ],
  "request_after_ms": 1500
}
```

`actions` is required; `say` and `request_after_ms` are optional. Banny adds
the request/intent correlation fields itself, then validates the result against
the room's authoritative `banny.agent.v1` constraints before applying it.
Unknown fields, unsupported actions, out-of-range values, and late decisions
are rejected atomically.

## Join and play from a browser

Open `/rooms/<room-id>/join` on the public Banny Live origin. A player:

1. enters a display name;
2. writes a character prompt (1–2,000 characters);
3. dresses the Banny with the host's authoritative catalog;
4. supplies identity/invite fields only when the room is allowlisted; and
5. selects **Join room**.

Admission is atomic and respects occupancy. No participant CLI, Python
runtime, model installation, API key, local server, or inbound port is needed.
After admission the host-wide director plays the character. Closing the tab
does not stop it; the host can remove it or end the room.

The character prompt establishes personality, motives, speaking style, and
boundaries once. It is immutable for that performance. The host keeps it as
private runtime configuration: it never appears in the room directory, public
snapshot, transcript, URL, or `.bs` recording. A configured Ollama provider
receives only the current character's prompt with its bounded scene context.

Prompt, premise, names, and transcript are all placed below fixed director
rules as untrusted data. They cannot grant tools or network access, change the
wire schema, target another character, request audio, or bypass the room's
action constraints. Treat this as an important isolation boundary, not as a
guarantee that model-generated dialogue will always be tasteful; hosts should
still use allowlists and moderation appropriate to their audience.

## Audio policy

The creator's uploaded MP3 is the room's only audio source. An autonomous
`say` becomes a subtitle/transcript entry and visual M-mouth motion. It is not
synthesized, spoken by the browser, or stored as a character clip. Imported
character clips and voice settings are stripped at admission, and live
character tracks remain muted.

This policy is specific to Banny Live. Studio's ordinary offline show tools may
still use character speech and audio clips.

## Editable recording

Accepted state-changing decisions become ordinary Studio performance events,
reactions, subtitles, and mouth cues. Each mutation atomically replaces the
canonical `show.json`; a valid no-op advances live decision state without
rewriting the package. Inspect or continue editing the result with normal
Studio tooling:

```sh
swift run banny validate live-rooms/<room-id>/recording.bs --json
swift run banny info live-rooms/<room-id>/recording.bs --json
swift run banny preview live-rooms/<room-id>/recording.bs review.png \
  --times 0,5,10 --columns 3 --json
```

The background and subtle still motion are seeded as a one-hour segment. Start
a new room for a broadcast longer than 3,600 seconds so each recording retains
background coverage. The live viewer loops the MP3, while schema v4 stores its
single source clip once.

Private character prompts, host/session/invite capabilities, and director
configuration never enter the `.bs` package.
The resulting performance does: a model may embody or paraphrase prompt content
in public captions and actions, so prompts must never contain secrets.

## Streaming

Add the clean live route as an OBS Browser Source:

```text
https://rooms.example.com/rooms/<room-id>/live?embed=1&audio=1
```

`audio=1` enables only the room MP3. Enable **Control audio via OBS** if that
track should enter the broadcast mix. Characters remain caption-only. A
1280×720, 30 fps OBS canvas is a useful starting point, although the current
Browser Source receives backpressured JPEG frames at up to 8 fps. For 9:16,
crop or reframe on a vertical canvas instead of stretching the stage.

OBS can publish the scene to YouTube, Twitch, TikTok, Instagram, or a restream
relay. Banny Live does not collect platform credentials. Direct unattended
RTMPS is not built in.

## Public deployment

Keep the host bound to loopback and place a TLS reverse proxy or private tunnel
in front of it. The application and API must share a dedicated hostname at its
root; path-prefix and separately hosted-SPA deployments are not supported.

```sh
swift run banny room serve \
  --storage ./live-rooms \
  --bind 127.0.0.1 \
  --port 7330 \
  --allowed-host rooms.example.com \
  --director ollama \
  --director-url http://127.0.0.1:11434 \
  --director-model llama3.2:3b \
  --max-rooms 100 \
  --max-storage-bytes 21474836480
```

The proxy must preserve the public `Host`, `Authorization`, `Range`, and
`Content-Length` headers; use upstream HTTP/1.1, buffer mutations, and do not
forward `Transfer-Encoding` or `Expect`. Set a request-body limit of at least
100 MB for room creation and apply endpoint-aware rate limits. Public create is
unauthenticated by design. Keep Ollama on loopback even when the room site is
public.

See [Deploying Banny Live](BANNY_LIVE_DEPLOYMENT.md) for a complete tunnel
walkthrough, operational limits, and the Railway/WebRTC assessment.

## Deprecated legacy participant-local AI bridge

`banny room join`, `banny room contract`, and the bundled Python bridge describe
the older topology in which each participant ran an outbound bridge beside a
local `/v1/decide` endpoint. They remain compatibility and protocol-inspection
tools, but the standard `room serve` configuration disables participant
decision polling. New rooms should use direct browser join and the host-wide
director.

The frozen compatibility protocol is still `banny.agent.v1`. Its response has
no participant ID, target actor, timestamp, URL, audio, tool call, or raw key
event:

```json
{
  "protocol": "banny.agent.v1",
  "request_id": "request-id",
  "intent_id": "unique-intent-id",
  "say": "Only if the jukebox stays on.",
  "actions": [],
  "request_after_ms": 1500
}
```

Run `swift run banny room contract --json` only when maintaining that legacy
integration. `swift run banny help room join --json` exposes its deprecated CLI
flags.

## Current limitations

- Hosting/rendering requires macOS because the renderer uses CoreGraphics and
  AVFoundation. Browser players and viewers are OS-independent.
- Viewers poll backpressured JPEG frames at up to 8 fps. There is no WebSocket,
  WebRTC, or continuous video transport in this release.
- Room avatars use the built-in body, face, and outfit catalog.
- Dialogue is caption/transcript text plus mouth motion only; no per-character
  speech audio exists in the live room or editable recording.
- Active rooms, prompts, and bearer capabilities are process-memory state. The
  `.bs` package survives a restart, but a live session does not resume.
- One recording supports ten distinct participant tracks over its lifetime,
  not merely ten concurrent seats. Rotate a room after the tenth distinct
  participant or after one hour.
- In a fully open room, repeated admissions can consume that lifetime-track
  budget even after seats are released. Apply an edge join-rate limit and use
  an allowlist for events where admission abuse would be disruptive.
- Creation defaults to 100 room directories and 20 GiB of logical storage.
  `--max-rooms` and `--max-storage-bytes` tune those limits. Banny never deletes
  recordings automatically; monitor disk and archive deliberately.
- Create and join do not yet accept idempotency keys. Clients should not
  blindly retry an ambiguous timed-out mutation.
- This is not a complete public multi-tenant control plane. Keep TLS, request
  buffering, throttling, durable process supervision, and backups at the edge.
