# Engine protocol

Start the worker with `python -m vocalcord_engine` from the engine's venv, with
the folder that holds `vocalcord_engine` as the working directory (`engine/` in a
checkout, `VocalCord.app/Contents/Resources/engine` in the app). It reads one JSON object per line on stdin and writes one
JSON object per line on stdout. Logs go to stderr only; anything a library prints
is redirected there too, so stdout carries nothing but replies.

## Messages

Request: `{"id": <string or number>, "cmd": "<command>", ...arguments}`.

Every reply carries the request's `id` and an `event`:

| event | meaning |
|---|---|
| `progress` | Work in progress. Always has `stage`; may repeat. |
| `result` | Success; the fields listed for each command. Last message for that id. |
| `error` | Failure. `code` is `invalid` (bad request or unreadable file), `cancelled`, or `failed` (unexpected; details in `message` and stderr). Last message for that id. |

A line that is not a JSON object gets `{"id": null, "event": "error", "code": "invalid", ...}`.

**Ordering.** `ping`, `status`, `cancel` and `shutdown` are answered at once.
`check_audio`, `edit_clip` and `prepare` run immediately, each on its own thread. `transcribe`, `render`,
`score`, `split`, `group_speakers`, `mix` and `unload` queue and run one at a
time in arrival order, so replies for different ids can interleave.

**Memory.** Only one large model is loaded at a time: Breeze (for `render`) or
Whisper (for `transcribe`, `split`, `score`). A command that needs the other one
unloads the current one first (Breeze 8-bit loads in 3–8 s, 4-bit in about
3 s, Whisper in 1–2 s). Render a batch of lines, then score the batch, to swap
once. The large model unloads after 120 s without a job. The two scoring models
(about 450 MB) stay loaded between scores and are freed before Breeze loads.

**Paths** are absolute (or start with `~`). Inputs for `transcribe`, `split`,
`check_audio` and `edit_clip` can be any file ffmpeg reads, audio or video (wav, m4a, mp3, mp4,
mov...); the first audio stream is used.

## Commands

### ping

```json
{"id": 1, "cmd": "ping"}
{"id": 1, "event": "result", "pong": true, "version": "0.1.0"}
```

### status

```json
{"id": 2, "cmd": "status"}
{"id": 2, "event": "result", "busy": "r7", "queued": 0, "idle_unload_s": 120.0,
 "large_model": "breeze:/Users/me/voice/models/Breeze-TTS-2-mlx-4bit",
 "small_models": ["speaker", "utmos"],
 "rss_mb": 38, "peak_rss_mb": 540, "footprint_mb": 3787, "peak_footprint_mb": 5383}
```

`busy` is the id of the running queued job, or null. `footprint_mb` is the
process memory Activity Monitor shows; it includes MLX's Metal buffers, which
`rss_mb` does not count. Peaks cover the life of the process.

### check_audio

Level check for a recording or upload, for the too-quiet / clipped / noisy /
cut-off warnings. Long files are streamed, not loaded whole.

```json
{"id": 3, "cmd": "check_audio", "audio": "/Users/me/upload.mov"}
{"id": 3, "event": "result", "duration": 10.6, "peak_dbfs": -13.8, "rms_dbfs": -32.5,
 "speech_dbfs": -26.8, "noise_floor_dbfs": -69.9, "clipping_ratio": 0.0, "warnings": []}
```

Measured on mono at 48 kHz in 50 ms frames. `speech_dbfs` is the 95th percentile
frame level, `noise_floor_dbfs` the 10th percentile. `clipping_ratio` is the
share of samples at or above 0.99 of full scale. `warnings` holds any of:

| warning | when |
|---|---|
| `quiet` | `speech_dbfs` < −35 |
| `clipped` | `clipping_ratio` ≥ 0.0001 |
| `noisy` | `noise_floor_dbfs` > −50 |
| `cut_off` | the first or last frame is within 20 dB of `speech_dbfs`: it starts or ends mid-word |

### edit_clip

One timeline clip: a span of a rendered line through the voice tools, with fades
and volume, written as a file the app plays and passes to `mix` as a line. Loads no model.

```json
{"id": 7, "cmd": "edit_clip", "audio": "/Users/me/Projects/p1/renders/abc.wav",
 "out": "/Users/me/Projects/p1/edits/9f2c.wav", "start": 0.0, "end": 3.2, "tempo": 1.0, "pitch": 0.0,
 "warmth": 0.0, "brightness": 0.0, "denoise": false, "gain_db": 0.0, "fade_in": 0.0, "fade_out": 0.0}
{"id": 7, "event": "result", "path": "/Users/me/Projects/p1/edits/9f2c.wav", "duration": 2.871}
```

| field | range (default) | meaning |
|---|---|---|
| `audio` | required | the source, usually a render (24 kHz WAV) |
| `out` | required | the WAV to write; its folder is created, an existing file replaced |
| `start` | ≥ 0 s (0) | where the clip starts in the source |
| `end` | > `start` s, or null (null) | where it ends; null or past the end of the source means the source's end |
| `tempo` | 0.5–2 (1) | speed, keeping the pitch (ffmpeg `atempo`) |
| `pitch` | −12 to 12 semitones (0) | keeping the duration (`asetrate`, `aresample`, `atempo`) |
| `warmth` | −12 to 12 dB (0) | low shelf at 200 Hz |
| `brightness` | −12 to 12 dB (0) | high shelf at 5 kHz |
| `denoise` | true or false (false) | ffmpeg `afftdn`, 12 dB of reduction, the noise floor taken from the clip's quietest frames |
| `gain_db` | −24 to 12 (0) | volume |
| `fade_in`, `fade_out` | 0–10 s (0) | raised-cosine fades, in seconds of the output (after `tempo`), shortened together when they would overlap |

- Order: trim, denoise, warmth and brightness, pitch, tempo, fades, gain, then
  clip to full scale. The result is mono 32-bit float WAV at 24 kHz, written to a
  temporary file in the same folder and renamed, so a reader never sees half a file.
- `duration` is the written file's length in seconds, exactly
  `(min(end, source length) − start) / tempo` to the sample.
- Without tempo, pitch, warmth, brightness or denoise it is plain arithmetic and
  runs no ffmpeg for a 24 kHz WAV source; otherwise one ffmpeg pass.
- `invalid` errors: a missing or out-of-range field, an unreadable source, or
  nothing left after trimming (`start` at or past the end of the source).

### transcribe

```json
{"id": 4, "cmd": "transcribe", "audio": "/Users/me/take.m4a"}
{"id": 4, "event": "progress", "stage": "load", "model": "whisper:mlx-community/whisper-large-v3-turbo-asr-8bit"}
{"id": 4, "event": "progress", "stage": "transcribe", "done": 10.6, "total": 10.6}
{"id": 4, "event": "result", "text": "Thanks for having me. Today I want to show you…",
 "words": [{"word": "Thanks", "start": 0.0, "end": 0.42}, {"word": "for", "start": 0.42, "end": 0.58}],
 "duration": 10.6}
```

Audio is transcribed in chunks of up to 30 s cut at the quietest point, with a
`transcribe` progress event (seconds done of total) after each. Words keep
Whisper's punctuation and capitals. Cancellable between chunks.

### split

Cuts free speech (a recording or an upload up to about 30 minutes) into clips at
natural pauses, each with its exact transcript.

```json
{"id": 5, "cmd": "split", "audio": "/Users/me/free-speech.mp4", "out_dir": "/Users/me/clips",
 "min_s": 3, "max_s": 20}
{"id": 5, "event": "progress", "stage": "transcribe", "done": 28.6, "total": 165.1}
{"id": 5, "event": "result", "text": "…", "duration": 165.1,
 "clips": [{"path": "/Users/me/clips/clip-001.wav", "start": 0.0, "end": 10.2, "duration": 10.2,
            "text": "Thanks for having me. Today I want to show you…"}]}
```

`min_s` and `max_s` are optional (3 and 20). Clips are mono 16-bit WAVs at the
source's sample rate, named `clip-001.wav` onward (existing files with those
names are overwritten). A cut goes at a pause (at least 0.25 s) or a sentence
end, preferring sentence ends and longer pauses; each edge is then moved to the
quietest point between the neighbouring words and outer silence is trimmed to
80 ms. A clip never spans a silence over 1.5 s; speech before such a silence too
short for a clip is left out. `text` is Whisper's words for the clip. Cancellable
between chunks and clips.

### group_speakers

Groups clips (usually from `split`) by who is speaking, for picking one speaker
in a file with several. Uses the speaker model from `score`; loads no large model.

```json
{"id": 13, "cmd": "group_speakers", "clips": ["/Users/me/clips/clip-001.wav", "/Users/me/clips/clip-002.wav", "…"]}
{"id": 13, "event": "progress", "stage": "embed", "done": 1, "total": 40}
{"id": 13, "event": "result", "groups": [["/Users/me/clips/clip-001.wav", "…"], ["/Users/me/clips/clip-002.wav", "…"]]}
```

- Each clip gets a WeSpeaker embedding; groups are joined by average-linkage
  clustering while their mean clip-to-clip cosine is at least `threshold`
  (optional, default 0.5; other speakers score up to about 0.22).
- `groups` holds the clip paths as given, largest group first. A group with
  fewer than 5% of the clips (or one clip) is a stray, such as laughter or a
  one-word reply, and is left out; the largest group is always kept, so a file
  with one speaker gives one group. No clips gives no groups.
- Cancellable between clips.

### render

```json
{"id": "r7", "cmd": "render", "model": "8bit", "cfg_scale": 4, "lufs": -16,
 "output": "/Users/me/Movies/VocalCord/intro.wav",
 "lines": [
   {"text": "Kuber keeps every savings circle honest.", "tone": "confident", "pause_after": 0.3, "seed": 7,
    "voice": {"audio": "/Users/me/voices/me/neutral.wav", "text": "Exact words of that take.",
              "pronunciations": {"Kuber": "Koo-ber"}}},
   {"text": "Thanks for having me. [pause 0.2] [breath] It was fun.", "tone": "Speak like an old friend",
    "voice": {"audio": "/Users/me/voices/guest/neutral.wav", "text": "Exact words of that take.",
              "breath": "/Users/me/voices/guest/inhale.wav"}}
 ]}
{"id": "r7", "event": "progress", "stage": "load", "model": "breeze:/Users/me/voice/models/Breeze-TTS-2-mlx-8bit"}
{"id": "r7", "event": "progress", "stage": "render", "done": 1, "total": 2,
 "line": {"index": 0, "text": "Kuber keeps every savings circle honest.",
          "spoken": "Koo-ber keeps every savings circle honest.", "start": 0.0, "end": 2.96}}
{"id": "r7", "event": "result", "path": "/Users/me/Movies/VocalCord/intro.wav",
 "timing_path": "/Users/me/Movies/VocalCord/intro.json", "duration": 6.81, "sample_rate": 24000,
 "lines": [{"index": 0, "text": "…", "spoken": "…", "start": 0.0, "end": 2.96},
           {"index": 1, "text": "…", "spoken": "…", "start": 3.26, "end": 6.81}]}
```

- `model`: `8bit` (default), `4bit`, or a Breeze model directory. `8bit`/`4bit`
  use `~/voice/models/Breeze-TTS-2-mlx-*` when present, otherwise the
  `mlx-community/Breeze-TTS-2-mlx-*` repo in the Hugging Face cache.
- `cfg_scale` 1–6 (default 4), `lufs` −30 to −10 (default −16).
- Each line: `text`, `voice.audio` + `voice.text` (reference take and its exact
  transcript), optional `voice.pronunciations` (whole word → respelling, applied
  to the spoken text only), optional `voice.breath` (0.05–2 s inhale, needed for
  `[breath]`), `tone` (a key: neutral, confident, sad, happy, angry, soft, slow,
  hesitant; or any free direction; default neutral), `pause_after` seconds 0–10
  (default 0; ignored on the last line), `seed` (default 7 + line index).
- Inline tags inside `text`: `[pause 0.30]`, `[breath]`, and `[tone]` or
  `[free direction]` to change tone mid-line; `(sigh)` is passed to Breeze.
- Each spoken part has its outer silence trimmed; the whole render is loudness
  normalised with ffmpeg. `start`/`end` are seconds in the output, end before
  `pause_after`. The same `lines` list is written to `timing_path`.
- `cancel` stops it before the next line or before the files are written;
  nothing is written.

### score

```json
{"id": 8, "cmd": "score", "audio": "/Users/me/Movies/VocalCord/intro.wav", "start": 0.0, "end": 2.96,
 "reference": "/Users/me/voices/me/neutral.wav", "text": "Kuber keeps every savings circle honest.",
 "hints": ["Kuber"]}
{"id": 8, "event": "result", "like_you": 74, "human": 3.01, "words": 67,
 "heard": "Kubler keeps every saving circle honest.", "similarity": 0.6927,
 "pitch_hz": 112.4, "reference_pitch_hz": 108.0, "longest_pause": 0.42}
```

- `start`/`end` (optional) score one line of a longer render, from the render's timing.
- `reference` is the line's voice take; `text` is the script line as written
  (not respelled). Tags in `[]` and cues in `()` are ignored.
- `hints` (optional): words Whisper should expect, added to its initial prompt.
  Pass the voice's pronunciation words (as written, such as `Kuber`) so a
  respelled render is heard with the script's spelling.
- `like_you` 0–100: speaker similarity. `similarity` is the raw cosine;
  `like_you = clamp((similarity − 0.25) / (0.85 − 0.25)) × 100` (see README).
- `human` 1.0–5.0: predicted naturalness (UTMOS).
- `words` 0–100: (1 − WER) × 100 between `text` and `heard` after normalising
  (lowercase, no punctuation, numbers spelled out), floored at 0.
- `heard`: what Whisper heard.
- `pitch_hz`, `reference_pitch_hz`: median pitch of the voiced 40 ms frames of the
  render and of the reference (autocorrelation, 70–400 Hz), 0 when none is voiced.
  The app flags a render more than 1.5 semitones off its take.
- `longest_pause`: the longest gap inside the render (20 ms frames 40 dB under
  its speech level, ends excluded), in seconds.

### mix

The export: rendered lines joined in order with their pauses, loudness-normalised,
as one file plus optional extras. Loads no model.

```json
{"id": 12, "cmd": "mix", "out_dir": "/Users/me/Movies/VocalCord/Launch film", "name": "Launch film",
 "format": "m4a", "lufs": -16, "per_line": false, "per_voice": false, "srt": true, "timing": false,
 "lines": [{"audio": "/Users/me/renders/a.wav", "text": "Meet the next chapter.", "voice": "Me",
            "pause_after": 0.5, "number": 1},
           {"audio": "/Users/me/renders/b.wav", "text": "Everything is ready.", "voice": "Me", "number": 3}]}
{"id": 12, "event": "progress", "stage": "read", "done": 1, "total": 2}
{"id": 12, "event": "result", "path": "/Users/me/Movies/VocalCord/Launch film/Launch film.m4a",
 "files": ["/Users/me/Movies/VocalCord/Launch film/Launch film.m4a",
           "/Users/me/Movies/VocalCord/Launch film/Launch film.srt"],
 "duration": 3.22, "lufs": -16.0,
 "lines": [{"index": 0, "number": 1, "text": "…", "voice": "Me", "start": 0.0, "end": 1.36},
           {"index": 1, "number": 3, "text": "…", "voice": "Me", "start": 1.86, "end": 3.22}]}
```

- `format`: `wav` (16-bit, default) or `m4a` (AAC 160 kbps); mono at 24 kHz.
- `lufs` −30 to −10 (default −16): two-pass ffmpeg loudnorm with a −1.5 dBTP
  ceiling, a plain gain unless the peak needs limiting. The result's `lufs` is
  measured on the written file (null for silence).
- Each line: `audio` (any ffmpeg-readable file), `text` (captions drop `[tags]`
  and `(cues)`), optional `voice` (a name, for per-voice files), `pause_after`
  seconds 0–10 (ignored on the last line), and `number`, the script line number
  used in names (default its position).
- Files, all in `out_dir`: `<name>.<format>` (first in `files`), and when asked
  `<name> line <number>.<format>` (`per_line`), `<name> <voice>.<format>`
  (`per_voice`: the whole timeline with only that voice's lines), `<name>.srt`
  (`srt`), `<name>.json` (`timing`, the `lines` list). If any of them exists,
  the name becomes `<name> 2`, `<name> 3`… so nothing is overwritten. `/`, `:`
  and `\` in names become `-`.
- `start`/`end` are seconds in the mix, end before `pause_after`.
- Consecutive lines with the same `number` are pieces of one script line (the
  timeline sends one entry per clip): they get one entry in the result's `lines`,
  the timing file and the captions, and one per-line file, running from the first
  piece's start to the last piece's end with the gaps between them. Its `index` is
  the first piece's position. A number that comes back later, apart from its run,
  gets its own entry, and its per-line file is `<name> line <number> (2).<format>`,
  then `(3)`….
- Files are made in a temporary folder and moved in at the end; a cancelled or
  failed mix leaves nothing.

### prepare

Downloads the models the engine needs into the Hugging Face cache: the chosen
Breeze model, Whisper, and the two scoring models. The app runs it during first-run
setup and when Settings switches to a model for the first time.

```json
{"id": 14, "cmd": "prepare", "model": "4bit"}
{"id": 14, "event": "progress", "stage": "list", "repo": "mlx-community/Breeze-TTS-2-mlx-4bit"}
{"id": 14, "event": "progress", "stage": "download", "done": 0, "total": 3042440182, "file": null}
{"id": 14, "event": "progress", "stage": "download", "done": 52428800, "total": 3042440182,
 "file": "mlx-community/Breeze-TTS-2-mlx-4bit/model.safetensors"}
{"id": 14, "event": "result", "downloaded": 3042440182}
```

- `model` (required): `4bit` or `8bit`. A Breeze copy under
  `~/voice/models/Breeze-TTS-2-mlx-*` counts as present, as in `render`.
- From Breeze and Whisper it takes the files mlx-audio loads (weights, configs,
  tokenizers); from the scoring models, their ONNX files. A file already in the
  cache for the repo's current revision is skipped.
- `done` and `total` are bytes, counting only what was missing when `prepare`
  started; `download` events come at most four times a second.
- Resumable: each file downloads to `<blob>.part` in the cache's `blobs` folder,
  and the next `prepare` continues it with an HTTP range request. Finished files
  stay, so a retry fetches only what is left.
- Cancellable between 1 MB chunks. One `prepare` runs at a time; a second waits.
- `HF_HOME` or `HF_HUB_CACHE` choose the cache, as for the rest of the engine.

### cancel

```json
{"id": 9, "cmd": "cancel", "target": "r7"}
{"id": 9, "event": "result", "cancelled": true}
{"id": "r7", "event": "error", "code": "cancelled", "message": "Cancelled"}
```

`cancelled` is false when `target` is not running or queued. A queued job is
dropped when it reaches the front; a running `render` stops before its next line
(a line in progress finishes first, up to about 30 s) and writes nothing,
`transcribe` and `split` before their next chunk, `group_speakers` before its
next clip, `mix` before its next file, `prepare` before its next 1 MB,
`edit_clip` before its ffmpeg pass and before it writes.

### unload

```json
{"id": 10, "cmd": "unload"}
{"id": 10, "event": "result", "unloaded": true}
```

Frees the large model and the scoring models. Queued like other jobs.

### shutdown

```json
{"id": 11, "cmd": "shutdown"}
{"id": 11, "event": "result", "shutdown": true}
```

Cancels running and queued jobs, waits for the current one to stop, replies, and
exits. Closing stdin does the same without a reply.
