# VocalCord

A Mac app for making voiceovers in your own cloned voices. It renders on your
Mac with the Breeze TTS 2 MLX model. The full plan is in
[docs/PLAN.md](docs/PLAN.md); Clone and Generate's script and rendering are
built; preview, outputs and export come next.

## Build and run

Requires macOS 26 or later and Xcode 26. Set up the engine first (see
[engine/README.md](engine/README.md)), run `./build.sh`, then open
`VocalCord.app`. The app starts the engine from `engine/` next to
`VocalCord.app`, or from `VOCALCORD_ENGINE_DIR`. `swift test` runs the tests;
`VOCALCORD_E2E=1 swift test --filter realEngine` renders two lines with the real
engine.

The local Breeze weights and their outputs are licensed for **research and
noncommercial use only**; use VocalCord for personal, nonmonetized videos. See
the [model license](https://huggingface.co/BreezeBlue/Breeze-TTS-2/blob/main/LICENSE).

## Clone

**New voice** offers a Fast clone (one 10–20 second clip) or a Full clone (a
guided session you can pause and resume). Each voice page lists its takes by
tone, with play, transcript, length, score and the main take per tone, plus a
Pronunciations list.

Voices live in `~/Library/Application Support/VocalCord/Voices`: `voices.json`
plus one folder per voice holding its take WAVs, with every other recording
kept in `raw/`. Voices from the old `library.json` are copied over on first
launch; the old files are left as they are.

## Generate

Each project is a script of lines, each with its text, voice, tone and pause.
Paste or import `.txt` or `.md` to split it into lines. **Render** renders every
line whose text, voice or tone has no version yet, then scores them; the button at
the end of a row adds a new version of that line. **Compare styles** renders
lines in other tones as extra versions. Projects live in
`~/Library/Application Support/VocalCord/Projects/<id>/`: `project.json` plus
the renders in `renders/`.

## Script tags

Put tags before each part, on separate lines or within one line:

```text
[confident] We built a faster way to find what matters.
[pause 0.30]
[sad] But the first attempt failed.
[pause 0.35]
[happy] Then we found a better answer.
```

- `[neutral]`, `[confident]`, `[sad]`, `[happy]` are built in. Any other text in
  brackets is a custom direction, such as `[Speak quietly, as if sharing a secret]`.
- `[pause 0.30]` inserts exactly 0.30 seconds of silence.
- `(sigh)` asks Breeze for a sigh inside a spoken part.
- `[breath]` inserts a recorded inhale. Record one in the app or choose a short
  WAV (0.05–2 seconds).

## directed_voice.py

The renderer also runs from the command line:

```sh
~/voice/venv/bin/python directed_voice.py \
  --script samples/directed-demo.txt \
  --reference samples/reference.wav \
  --reference-text-file samples/reference.txt \
  --model ~/voice/models/Breeze-TTS-2-mlx-8bit \
  --output samples/directed-demo.wav
```

- `--breath-audio path/to/inhale.wav` is needed when the script uses `[breath]`.
- `--all-styles` renders four WAVs from one model load, ending in `-neutral`,
  `-confident`, `-sad`, and `-happy`.
- Use `~/voice/models/Breeze-TTS-2-mlx-4bit` for the lighter model.

The output WAV is normalized for listening. A JSON file with the same name holds
each section's start and end time for editing or video sync.

## License

The code is licensed under [PolyForm Noncommercial 1.0.0](LICENSE.md). It is
free for personal use, not for commercial use. Breeze has its own license (see
above); each user downloads it separately.
