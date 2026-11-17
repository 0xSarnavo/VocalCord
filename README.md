# VocalCord

A macOS menu bar app for making voiceovers in your own voice. It renders on your
Mac with the Breeze TTS 2 MLX model. A full rewrite is planned in
[docs/PLAN.md](docs/PLAN.md).

## Build and run

Requires macOS 26 or later, Xcode command line tools, ffmpeg, and Breeze TTS 2
installed under `~/voice` (Python in `~/voice/venv`, models in `~/voice/models`).
Run `./build.sh`, then open `VocalCord.app`. Launch with `--video-window` or
`--library-window` to open a window straight away.

The local Breeze weights and their outputs are licensed for **research and
noncommercial use only**; use VocalCord for personal, nonmonetized videos. See
the [model license](https://huggingface.co/BreezeBlue/Breeze-TTS-2/blob/main/LICENSE).

## Video voiceover

Open **VocalCord → Video voiceover…** from the menu bar. Paste your script and
choose **Directed voiceover** to follow the direction tags, or **Compare styles**
to render the same words in neutral, confident, sad, and happy voices. Compare
mode keeps pauses and recorded breaths but replaces the direction tags. Each
result gets its own **Play** and **Show** buttons.

The 8-bit model is the default; choose 4-bit for a faster render. The sliders set
direction strength, final loudness, and the length added by the **Pause** button.
Results go to `~/Movies/VocalCord` with matching `.json` timing files. The model
loads only while rendering and is never downloaded again.

You can pick a saved voice. A section tagged `[sad]`, for example, uses that
voice's sad take when it has one; other sections use the current reference.
Style labels only choose reference recordings; Breeze still uses one reference
and its exact transcript per section.

## Voice library

Open **VocalCord → Voice library…** to listen to your reference voice, create a
voice from your own recording, or add takes to an existing voice. Record or
import 3–60 seconds of audio and enter the exact words spoken; **Edit words**
fixes them later. Takes and transcripts live in
`~/Library/Application Support/VocalCord/Voices`. Voices from the app's old data
folder are copied there on first launch.

Label each take as neutral, confident, happy, sad, angry, soft, slow, or
hesitant. **Clean selected take** makes a denoised, normalized copy and keeps the
original. To compare takes, select one, enter a test line, and choose **Generate
comparison**: Current and New take render with one model load. Test files go to
`~/Movies/VocalCord/Voice tests`. **Use** makes a take the current reference.

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

The script editor has buttons for these tags.

## directed_voice.py

The renderer behind both windows also runs from the command line:

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
