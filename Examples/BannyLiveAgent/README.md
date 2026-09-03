# Banny Live reference agent

Run the dependency-free toy agent:

```sh
python3 Examples/BannyLiveAgent/server.py
```

Then point a participant bridge at `http://127.0.0.1:7331`. The bridge appends
`/v1/decide`, sends `banny.agent.v1` context, validates the response, and sends
only accepted intent back to the room. The room host never receives or calls
this localhost URL.

Replace `decide()` with your own local model call. Keep responses under 16 KiB,
speech at 280 characters or fewer, and actions at four or fewer. Held actions
must last 80–3000 ms. Raw key events, arbitrary URLs, timestamps, and attempts
to control another participant are not part of the protocol.
