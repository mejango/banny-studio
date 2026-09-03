# Deploying Banny Live

Banny Live has one Apple-native authority per host process. That process owns
room admission, the host-wide character director, canonical event order,
CoreGraphics/AVFoundation rendering, and the editable `.bs` recording. Players
join directly in a browser; they do not run a CLI, local AI service, or inbound
port. The director is either built in or a loopback Ollama model on the host.

## Recommended now: creator-hosted Mac plus an HTTPS tunnel

This is the smallest topology which lets people on ordinary Internet
connections create, watch, and play without opening an inbound port on either
the creator's or participants' routers:

```text
creator / player / viewer browser / OBS
                   |
               public HTTPS
                   |
            Cloudflare Tunnel
                   |
           127.0.0.1:7330 on macOS
                   |
 Banny authority + director + renderer + recording.bs
                   |
       optional Ollama on 127.0.0.1:11434
```

Use an always-on Mac running macOS 14 or newer. For MacStadium, copy the signed
standalone release and its external checksum to the host, then verify and
install it:

```sh
shasum -a 256 -c banny-2.1.0-macos.zip.sha256
ditto -x -k banny-2.1.0-macos.zip .
cd banny-live-host-2.1.0-macos
sudo ./install.sh \
  --allowed-host rooms.example.com \
  --port 7330 \
  --max-rooms 100 \
  --max-storage-bytes 21474836480
```

The archive contains the universal arm64/x86_64 CLI, its SwiftPM web bundle,
the deprecated compatibility bridge, Banny art, an integrity manifest, and the
macOS installer. The installer verifies a relocated live server before
activation, runs it as a disabled `_bannylive` role account, makes recordings
private, installs health/log-rotation jobs, and rolls back the launchd
configuration if the new service does not become healthy. Official archives
are Developer-ID signed and notarized. A source-built pilot is ad-hoc signed
and requires the explicit `--allow-adhoc-signature` installer option.

To build that pilot archive from a source checkout, run the complete packaging
pipeline rather than copying `.build/release/banny` by itself:

```sh
tools/build-live-distribution.sh 2.1.0 --adhoc
tools/test-live-distribution.sh dist/banny-2.1.0-macos.zip 2.1.0
```

The builder already runs the second command and keeps the artifacts in `dist/`
only after it passes; the explicit invocation is useful when rechecking a transferred
archive. Install an ad-hoc pilot by adding `--allow-adhoc-signature` to the
`install.sh` command above. Official release maintainers instead run
`tools/release-cli.sh 2.1.0` with the configured Developer ID and notary profile.

Choose a dedicated hostname such as `rooms.example.com`. Banny Live must be at
the root of that hostname; path-prefix deployments such as
`example.com/banny/` are not supported. The installer pins the origin to
`127.0.0.1:7330` and applies the exact Host allowlist. A manual development
launch equivalent is:

```sh
.build/release/banny room serve \
  --storage '/Users/banny/Library/Application Support/Banny Studio/Live Rooms' \
  --bind 127.0.0.1 \
  --port 7330 \
  --allowed-host rooms.example.com \
  --max-rooms 100 \
  --max-storage-bytes 21474836480
```

`--allowed-host` is repeatable. Add `--allowed-host 127.0.0.1` only if local
browsers must also reach the origin directly. Do not bind a same-machine tunnel
origin to `0.0.0.0`. The shown admission limits are also the defaults: 100
persisted/current rooms and 20 GiB of logical room-storage bytes.

### Host-wide Ollama director on an M1 Mac

Ollama supports Apple M-series Macs through Metal. Follow its
[macOS installation guide](https://docs.ollama.com/macos), launch the app, and
pull Banny's default model:

```sh
ollama pull llama3.2:3b
```

The app normally starts the loopback API. If it is not running, start it in a
dedicated terminal with `ollama serve`. Verify the model locally before opening
the public route, then launch Banny:

```sh
.build/release/banny room serve \
  --storage ./live-rooms \
  --bind 127.0.0.1 \
  --port 7330 \
  --allowed-host rooms.example.com \
  --director ollama \
  --director-url http://127.0.0.1:11434 \
  --director-model llama3.2:3b
```

The standalone installer currently provisions the built-in director; use a
supervised manual launch for an Ollama pilot. Do not expose port 11434 or proxy
it through the public hostname. Banny accepts only a numeric-loopback HTTP
origin, bounds request/response bytes and deadlines, declines redirects, and
validates strict action JSON before it reaches the room.

The installed paths are:

- immutable code: `/Library/Application Support/Banny Live/releases/<version>`
- recordings: `/Library/Application Support/Banny Live/rooms`
- logs: `/Library/Logs/Banny Live`
- launchd service: `system/com.banny.live`

Before every upgrade, disable the public Tunnel route, end all rooms, and run
the new archive's installer. Live seats, prompts, and token digests are
intentionally memory-only; restarting does not restore or finalize
an active room. The installer therefore fails closed unless all visible rooms
are ended. `--force-restart` is a recovery override, not a finalization tool.

Room creation fails with HTTP `429 room_limit_reached` at the room limit and
HTTP `507 storage_quota_exceeded` when a conservative staging reservation would
cross the storage limit. Admission is serialized before any upload is staged;
failed admission does not create a partial room. Existing recording directories
remain in the count after a restart. Symlink targets are never followed, and
Banny never deletes or archives a recording automatically.

Install Cloudflare's connector on the Mac:

```sh
brew install cloudflared
```

For a stable deployment, create a remotely managed tunnel in the Cloudflare
dashboard:

1. Open **Zero Trust → Networks → Connectors → Cloudflare Tunnels**, create a
   tunnel, choose macOS, and run the connector command Cloudflare provides.
   Treat its tunnel token as a secret.
2. Add a **Published application** route with hostname `rooms.example.com` and
   service URL `http://127.0.0.1:7330`.
3. Under **Additional application settings → HTTP settings**, set
   **HTTP Host Header** to `rooms.example.com` and turn
   **Disable Chunked Encoding** on. Banny deliberately rejects transfer-coded
   requests and requires `Content-Length` on mutations.
4. Keep both the Banny process and `cloudflared` supervised and running.
5. Visit `https://rooms.example.com/v1/rooms`. A healthy empty host returns a
   JSON room list.
6. Open `https://rooms.example.com/create`, create a room, and use its Join
   page on a second network to test a real participant.

Cloudflare documents the dashboard tunnel flow and macOS installation here:

- <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/>
- <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/>
- <https://developers.cloudflare.com/tunnel/advanced/origin-parameters/>
- <https://developers.cloudflare.com/support/troubleshooting/http-status-codes/4xx-client-error/error-413/>

For a disposable development test, start a Quick Tunnel:

```sh
cloudflared tunnel \
  --url http://127.0.0.1:7330 \
  --http-host-header 127.0.0.1 \
  --no-chunked-encoding
```

Run Banny with its default loopback Host policy for this command; the explicit
origin Host override makes the random public hostname unnecessary at the
origin. Quick Tunnels are explicitly for testing, have no uptime guarantee,
and currently cap in-flight requests; use a named tunnel for a real room.

### Player flow

Send the HTTPS room link to any player. They open
`https://rooms.example.com/rooms/<room-id>/join`, enter a name and private
character prompt, dress the Banny, add an invite only for an allowlisted room,
and select **Join room**. The same-origin browser request admits the character
directly; there is no participant bridge or local-agent connection.

The prompt is immutable for that performance. It is sent only to the configured
host-side director and is omitted from URLs, public snapshots, transcripts,
and the `.bs` recording. Browser close does not remove the autonomous
character; the room host can kick it or end the room.

`banny room join` and the Python bridge are deprecated compatibility tools for
the old participant-local AI protocol. Standard `room serve` disables that
polling interface, so do not present the bridge as the public join path.

### Broadcast flow

Add this URL as an OBS Browser Source:

```text
https://rooms.example.com/rooms/<room-id>/live?embed=1&audio=1
```

`audio=1` enables only the creator-supplied background MP3. Character dialogue
is caption-only. In OBS, enable **Control audio via OBS** on the Browser Source;
browser autoplay policy can otherwise leave the MP3 silent. OBS or a restream
provider owns the YouTube, Twitch, TikTok, and Instagram stream credentials.

### Operating checklist

- Keep port 7330 private; expose only the tunnel/TLS edge.
- When using Ollama, keep port 11434 on numeric loopback and pre-pull the model
  before a room opens. Monitor host memory and director latency under the
  intended occupancy.
- Preserve the public `Host` header. Banny rejects authorities not named by an
  exact `--allowed-host` option before buffering request bodies.
- Keep the app at a dedicated hostname root and proxy upstream over HTTP/1.1.
- Preserve `Authorization`, `Range`, and `Content-Length`; buffer request bodies
  at the edge rather than forwarding chunked uploads.
- Set an edge request-body limit of 100 MB and create/join rate limits. Banny's
  finite room/storage admission defaults are 100 rooms and 20 GiB; tune them
  with `--max-rooms` and `--max-storage-bytes`. The application limits decoded
  background-plus-MP3 media to 70 MiB so its base64 JSON remains below that edge
  ceiling. Public room creation is intentionally unauthenticated.
- Monitor free disk space. The storage quota protects creation admission and
  its worst-case staging allocation; an active room's canonical `show.json`
  continues to grow after admission. Archive recordings deliberately instead
  of automating destructive retention.
- Back up `live-rooms/*/recording.bs`. Active sessions, private prompts, and
  token digests are in memory and do not resume after a host-process restart.
- The creator's MP3 is the sole audio source. `say` is captions and mouth
  motion; do not provision character-audio mixers or speech credentials.
- Avoid restarting either process during a live room. Rotate rooms at one hour
  or ten lifetime participant tracks, whichever comes first.

## Why the complete app does not run on Railway today

Railway deploys services as container images, and its automatic Railpack
runtime does not list Swift. A custom Swift Dockerfile would still produce a
Linux binary. This repository's host imports Apple Network.framework,
CoreGraphics, ImageIO, UniformTypeIdentifiers, and AVFoundation, and the Swift
package declares macOS/iOS platforms. A Linux container therefore cannot build
or run the current renderer.

Relevant platform documentation:

- Railway services are container deployments:
  <https://docs.railway.com/services>
- Railpack's supported languages:
  <https://docs.railway.com/builds/railpack>
- Railway public domains and automatic TLS:
  <https://docs.railway.com/networking/public-networking>
- Railway public-network limits:
  <https://docs.railway.com/networking/public-networking/specs-and-limits>
- Swift's separate Linux and macOS build triples:
  <https://www.swift.org/documentation/server/guides/building.html>

Deploying only `Resources/Web` to Railway is not sufficient: the site expects
its room API, frames, and MP3 at same-origin `/v1` routes.

### Useful Railway phase two

The productive Railway split is a small Linux-compatible relay, not the
renderer itself:

```text
browser → Railway HTTPS relay
              |
     authenticated outbound WSS
              |
     macOS Banny worker + director
```

That relay would serve the site, rate-limit public routes, cache the newest
snapshot/JPEG/MP3, and route correlated commands. The Mac would keep authority,
rendering, admission, and `.bs` recording, connecting outbound so it needs no
public inbound port. This relay/worker protocol is not implemented in the
current MVP; deploying the monolith to Railway or a static-only service would
produce a non-working game.

Once that target exists, the Railway steps are:

1. Deploy its Dockerfile from GitHub and bind the relay to `0.0.0.0:$PORT`.
2. Configure a health endpoint and worker-auth signing secret.
3. Generate a Railway domain or attach a custom domain; Railway terminates TLS.
4. Keep one relay replica until routing/session state moves to Redis or a
   database.
5. Start the Mac worker with the relay's `wss://` URL and credential.
6. Exercise create, browser join, autonomy, frame, MP3, worker reconnect, and room end
   across a relay redeploy before using it for a live broadcast.

Railway supports HTTP/1.1 and WebSockets at its public edge, so this future
relay fits its networking model. Do not attach the authoritative `.bs` volume
to a horizontally scaled relay; completed recordings should be uploaded to
durable object storage instead.

## Why pure peer-to-peer is not the better first deployment

Pure WebRTC does not remove infrastructure. Peers still need a signaling
service plus ICE servers, and real-world NAT traversal commonly needs a TURN
relay. More importantly, Banny Live needs one canonical authority to enforce
occupancy, order bot intents, render one coherent scene, and write one editable
recording. Letting every participant merge `.bs` state would sacrifice those
invariants.

The current creator-hosted topology is already a practical host-star: one Mac
is authoritative and every browser makes an outbound connection. A future
WebRTC version could deliver encoded video or lower-latency snapshots, but it
should remain a star around that authority—not an all-participant mesh. At ten
participants, a star has ten host links; a full mesh has forty-five peer links.
WebRTC's own documentation also notes that signaling is separate and that TURN
is commonly required:

- <https://webrtc.org/getting-started/peer-connections>
- <https://webrtc.org/getting-started/turn-server>

For this release, an HTTPS tunnel to the creator's Mac is simpler, safer, and
closer to peer-hosted operation than inserting Railway or WebRTC into the live
render path.
