# Engine protocol

Start the worker with `engine/.venv/bin/python -m vocalcord_engine` (working
directory `engine/`). It reads one JSON object per line on stdin and writes one
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
`check_audio` runs immediately on its own thread. `transcribe`, `render`,
`score`, `split` and `unload` queue and run one at a time in arrival order, so
replies for different ids can interleave.

**Memory.** Only one large model is loaded at a time: Breeze (for `render`) or
Whisper (for `transcribe`, `split`, `score`). A command that needs the other one
unloads the current one first (Breeze 8-bit loads in 3–8 s, 4-bit in about
3 s, Whisper in 1–2 s). Render a batch of lines, then score the batch, to swap
once. The large model unloads after 120 s without a job. The two scoring models
(about 450 MB) stay loaded between scores and are freed before Breeze loads.

**Paths** are absolute (or start with `~`). Inputs for `transcribe`, `split` and
`check_audio` can be any file ffmpeg reads, audio or video (wav, m4a, mp3, mp4,
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

Level check for a recording or upload, for the too-quiet / clipped / noisy
warnings. Long files are streamed, not loaded whole.

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

### transcribe

```json
{"id": 4, "cmd": "transcribe", "audio": "/Users/me/take.m4a"}
{"id": 4, "event": "progress", "stage": "load", "model": "whisper:mlx-community/whisper-large-v3-turbo-asr-8bit"}
{"id": 4, "event": "progress", "stage": "transcribe", "done": 10.6, "total": 10.6}
{"id": 4, "event": "result", "text": "Every voice tells a story…",
 "words": [{"word": "Over", "start": 0.0, "end": 1.22}, {"word": "past", "start": 1.22, "end": 1.64}],
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
            "text": "Every voice tells a story…"}]}
```

`min_s` and `max_s` are optional (3 and 20). Clips are mono 16-bit WAVs at the
source's sample rate, named `clip-001.wav` onward (existing files with those
names are overwritten). A cut goes at a pause (at least 0.25 s) or a sentence
end, preferring sentence ends and longer pauses; each edge is then moved to the
quietest point between the neighbouring words and outer silence is trimmed to
80 ms. A clip never spans a silence over 1.5 s; speech before such a silence too
short for a clip is left out. `text` is Whisper's words for the clip. Cancellable
between chunks and clips.

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
- `cancel` stops it before the next line; nothing is written.

### score

```json
{"id": 8, "cmd": "score", "audio": "/Users/me/Movies/VocalCord/intro.wav", "start": 0.0, "end": 2.96,
 "reference": "/Users/me/voices/me/neutral.wav", "text": "Kuber keeps every savings circle honest."}
{"id": 8, "event": "result", "like_you": 74, "human": 3.01, "words": 67,
 "heard": "Kubler keeps every saving circle honest.", "similarity": 0.6927}
```

- `start`/`end` (optional) score one line of a longer render, from the render's timing.
- `reference` is the line's voice take; `text` is the script line as written
  (not respelled). Tags in `[]` and cues in `()` are ignored.
- `like_you` 0–100: speaker similarity. `similarity` is the raw cosine;
  `like_you = clamp((similarity − 0.25) / (0.85 − 0.25)) × 100` (see README).
- `human` 1.0–5.0: predicted naturalness (UTMOS).
- `words` 0–100: (1 − WER) × 100 between `text` and `heard` after normalising
  (lowercase, no punctuation, numbers spelled out), floored at 0.
- `heard`: what Whisper heard.

### cancel

```json
{"id": 9, "cmd": "cancel", "target": "r7"}
{"id": 9, "event": "result", "cancelled": true}
{"id": "r7", "event": "error", "code": "cancelled", "message": "Cancelled"}
```

`cancelled` is false when `target` is not running or queued. A queued job is
dropped when it reaches the front; a running `render` stops before its next line
(a line in progress finishes first, up to about 30 s), `transcribe` and `split`
before their next chunk.

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
