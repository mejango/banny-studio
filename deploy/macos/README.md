# Banny Live macOS host

This archive is a complete, relocatable Banny Live host for macOS 14 or newer.
It includes the universal `banny` executable, the direct browser-join website,
the host-wide built-in director, and the Banny character catalog. Players need
only a current browser and an Internet connection. A deprecated compatibility
bridge remains available for old integrations, but it is not the public join
path.

## Quick start on your M1 Mac

After checking the downloaded archive hash, extract it and run the host directly:

```sh
shasum -a 256 -c banny-2.1.0-macos.zip.sha256
ditto -x -k banny-2.1.0-macos.zip .
cd banny-live-host-2.1.0-macos

./banny room serve \
  --storage "$HOME/Library/Application Support/Banny Live/rooms" \
  --bind 127.0.0.1 \
  --port 7330 \
  --director built-in
```

Open `http://127.0.0.1:7330/create`. The built-in director needs no model or
API key. For richer local dialogue, install and start Ollama, pull a model once,
and replace the final director option with:

```sh
--director ollama \
--director-url http://127.0.0.1:11434 \
--director-model llama3.2:3b
```

Stop a foreground pilot with Control-C after ending its rooms. A process restart
cannot resume an active room, although its last atomically written `.bs` remains
on disk.

## Optional always-on service

1. Use a Mac running macOS 14 or newer. Apply OS updates and enable FileVault
   if your remote-access setup supports it.
2. Copy this archive and its separately published `.sha256` file to the Mac.
   Verify it before extraction:

   ```sh
   shasum -a 256 -c banny-VERSION-macos.zip.sha256
   ditto -x -k banny-VERSION-macos.zip .
   cd banny-live-host-VERSION-macos
   ```

3. Point a dedicated DNS hostname, such as `rooms.example.com`, at a
   Cloudflare Tunnel. Do not expose port 7330 directly.
4. Install:

   ```sh
   sudo ./install.sh \
     --allowed-host rooms.example.com \
     --port 7330 \
     --max-rooms 100 \
     --max-storage-bytes 21474836480
   ```

   Official releases require a valid Developer ID signature. A locally built
   pilot archive is ad-hoc signed and is rejected unless you consciously add
   `--allow-adhoc-signature`.

The installer verifies every packaged file, the universal architectures, the
code signature, and a real relocated room server. It creates a disabled hidden
`_bannylive` role account, stores immutable code under
`/Library/Application Support/Banny Live/releases/`, keeps recordings private
under `.../rooms/`, installs three system LaunchDaemons, and rolls back the
service configuration if activation does not become healthy.

Useful checks:

```sh
sudo launchctl print system/com.banny.live
curl --fail --header 'Host: rooms.example.com' \
  http://127.0.0.1:7330/v1/rooms
tail -f '/Library/Logs/Banny Live/stdout.log'
```

## Cloudflare Tunnel

Install `cloudflared` separately. Banny's installer intentionally never accepts
the tunnel credential. With a named tunnel, configure:

- Public hostname: `rooms.example.com`
- Origin service: `http://127.0.0.1:7330` (not `localhost`)
- HTTP Host Header: `rooms.example.com`
- Disable Chunked Encoding: **On**

Use `cloudflared`'s token-file support, keep that file `root:wheel` mode `0600`,
and never put the token in a command argument, plist, Banny environment, log,
or support bundle. At the edge, require HTTPS, preserve `Authorization`,
`Range`, and `Content-Length`, cap request bodies below 100 MB, and rate-limit
anonymous room creation. The application also enforces the installed total
room-count and storage-byte limits.

## Upgrades

An active Banny room cannot survive a process restart. Before installing a new
version:

1. Disable or drain the public Tunnel route.
2. End every room from its host controls and verify the room list reports each
   room as ended.
3. Run the new archive's `install.sh` with the same Host, port, and limits.
4. Re-enable the route only after the installer reports healthy.

The installer fails closed if it cannot prove every stored room is ended. Use
`--force-restart` only after you have independently ended the rooms; it does
not finalize an interrupted recording. Releases are immutable, and the prior
working release is retained for rollback.

## Data and operations

- Recordings: `/Library/Application Support/Banny Live/rooms/*/recording.bs`
- Logs: `/Library/Logs/Banny Live/`
- Service: `com.banny.live`
- Health check: every five minutes; it reports but never restarts a room
- Log rotation: copy/truncate at 20 MiB, seven retained files

Back up completed `recording.bs` directories to storage outside this Mac. The
service's room/session credentials are held only in memory, so preserve the
Mac and recordings but do not schedule unattended service restarts during a
live room. Configure MacStadium disk alerts and keep substantially more free
space than the application quota.

## Uninstall

Code and jobs can be removed without deleting recordings or logs:

```sh
sudo ./uninstall.sh --force-restart
```

The acknowledgement is required while the launchd service is loaded. End all
rooms and drain the public route first; uninstall cannot finalize a live room.

Permanent data deletion is intentionally two-step:

```sh
sudo ./uninstall.sh --force-restart --purge-data --yes
```

The `_bannylive` role account is preserved so an uninstall never reassigns its
UID to unrelated files.
