# Speech, lip sync, captions, and audio

Read this before generating speech, importing dialogue, editing mouth timing,
or mixing tracks.

List exact installed voice IDs:

```sh
banny voices --language en --json
```

Generate one line:

```sh
banny tts show.bs --character 1 \
  --text "Welcome to the show." --at 1.2 \
  --voice <installed-id> --preset warmNarrator --flavor 0.65 --json
```

Generate speech for existing nonempty captions:

```sh
banny tts show.bs --character 1 --captions --voice <installed-id> --json
```

Caption mode uses each caption's start and replaces prior CLI-generated speech
clips for that character while preserving imported and microphone takes. A
single `--text` appends a clip and matching caption unless `--no-caption` is
intentional. Compare reported clip durations with subtitles and leave readable
gaps.

Voice recipes are portable and non-destructive. Exact presets and ranges come
from `capabilities --json` and `schema --compact`. Never invent a voice ID.

TTS derives binary open/closed mouth timing. Use `lipsync` for imported takes:

```sh
banny media import show.bs take.wav \
  --character 1 --at 6 --kind microphone --lipsync --json
banny lipsync show.bs --character 1 --clip <clip-id> --json
```

Use `--clear` to remove precise mouth cues only when replacing them. Keep
automatic mouth enabled unless manual mouth performance is deliberate.

Muted tracks stay visually active but silent. Solo restricts monitoring/export
audio to soloed tracks. Avoid setting both on one track. Use short review
renders to judge timing and mix; preview PNGs contain no audio.

Confirm the user has rights to imported audio and authorization for personal or
third-party voices.
