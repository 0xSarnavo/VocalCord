# VocalCord engine

The local Python worker behind VocalCord: Breeze renders, Whisper transcripts and
clips, and the three line scores. The app runs it as a long-lived process and
talks JSON lines over stdin/stdout; every command is in [PROTOCOL.md](PROTOCOL.md).

## Setup

VocalCord.app installs the engine on first run: its bundled uv makes a Python
3.13 venv in `~/Library/Application Support/VocalCord/Engine` from
`requirements.txt`, and `prepare` downloads the models. For development:

```sh
cd engine
python3.13 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m vocalcord_engine        # the worker; logs on stderr
.venv/bin/python -m pytest                  # all tests; -m "not slow" skips the model test
```

ffmpeg comes from PATH or Homebrew when there is one, else from the
imageio-ffmpeg wheel. Models live in the Hugging Face cache (`HF_HOME`); without
`prepare`, Whisper and the scoring models download on first use. Breeze is read
from `~/voice/models/Breeze-TTS-2-mlx-{8bit,4bit}` when present, else from the
`mlx-community` repo. The slow test needs a private recording at
`samples/reference.wav` with its transcript in `samples/reference.txt`, and skips
without them. No PyTorch.

## Models

| Use | Model | Size | Licence | Why |
|---|---|---|---|---|
| Speech | Breeze TTS 2, MLX [8-bit](https://huggingface.co/mlx-community/Breeze-TTS-2-mlx-8bit) / [4-bit](https://huggingface.co/mlx-community/Breeze-TTS-2-mlx-4bit) | 4.3 / 2.8 GB | Research, non-commercial | Existing renderer, ported from `directed_voice.py` |
| Transcripts (`heard`, clips) | [mlx-community/whisper-large-v3-turbo-asr-8bit](https://huggingface.co/mlx-community/whisper-large-v3-turbo-asr-8bit) | 868 MB | MIT (OpenAI Whisper) | Best English accuracy among MLX Whisper builds under 1.2 GB; ships the alignment heads mlx-audio uses for word timestamps. Transcribed the sample reference word for word. |
| `like_you` | WeSpeaker ResNet34-LM, [voxceleb_resnet34_LM.onnx](https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM) | 26.5 MB | CC BY 4.0 (VoxCeleb) | Small ONNX speaker-verification model (the one pyannote uses). Features via [kaldi-native-fbank](https://github.com/csukuangfj/kaldi-native-fbank) (Apache 2.0), as WeSpeaker's own ONNX demo. |
| `human` | UTMOS22 strong, [utmos22_strong.onnx](https://huggingface.co/TigreGotico/utmos-onnx) | 411 MB | MIT | MOS predictor trained on synthetic-speech ratings (VoiceMOS 2022). ONNX export of [tarepan/SpeechMOS](https://github.com/tarepan/SpeechMOS) from [sarulab-speech/UTMOS22](https://github.com/sarulab-speech/UTMOS22); the export reports a max deviation of 6e-6 from the PyTorch model. |

Considered: Parakeet TDT 0.6B v2 (CC BY 4.0) has lower English WER and much
faster, native timestamps, but its MLX weights are fp32 only (2.5 GB).
Whisper turbo 4-bit (464 MB) matched 8-bit on the samples; kept 8-bit for
accuracy margin. DNSMOS (MIT, 0.2–1.2 MB) rates noise suppression, not
naturalness; NISQA has non-commercial weights; UTMOSv2 needs PyTorch.

## Scores

- `like_you` = clamp((cos − 0.25) / (0.85 − 0.25)) × 100, where cos is the
  cosine similarity of the render's and the reference's speaker embeddings.
  Measured here against the sample reference: other speakers (Kokoro, Phonon,
  Breeze voice designs, Breeze cloning a Kokoro voice) −0.15 to 0.22; Breeze
  clones of the reference 0.66–0.80 for 2–5 s lines and 0.80 for a 12 s take;
  another real recording of the same person 0.84. So 0 % is just above every
  other speaker seen and 100 % is a real recording of the same voice.
- `human` is UTMOS clamped to 1–5. It rates recording quality too: the sample
  reference recording scores 3.0, Breeze clones of it 3.0–3.7, clean
  Kokoro/Phonon voices 4.2–4.5. Audio over 20 s is scored in 20 s windows.
- `words` = (1 − WER) × 100, floored at 0, after lowercasing, dropping
  punctuation, `[tags]` and `(cues)`, and spelling out numbers. It compares the
  script as written, so a respelled brand name Whisper writes differently
  ("Kuber" heard as "Cougar") costs a word, unless the app passes it in `hints`.

Clone vs other speaker, same three lines, rendered by the engine (8-bit unless noted):

| Render | like_you | human | words |
|---|---|---|---|
| Breeze clone of the reference | 92, 74, 68 | 3.74, 3.01, 3.31 | 100, 67, 100 |
| Breeze clone, 4-bit | 81, 69, 72 | 3.67, 3.62, 3.45 | 100, 67, 100 |
| Breeze cloning a Kokoro voice | 0, 0, 0 | 4.18, 4.32, 4.24 | 100, 83, 100 |
| Phonon "Hugh" / Kokoro "am_michael" (line 1) | 0 / 0 | 4.27 / 4.30 | 100 / 100 |

## Timings

M1, 8 GB, macOS 26, with a browser holding about 6 GB, so the system was
swapping; expect faster with other apps closed.

| Step | Time |
|---|---|
| Breeze 4-bit render | 8–18 s per line of 2–5 s audio; load 2.5–3.5 s |
| Breeze 8-bit render | 38–55 s per line of 2.5–4 s audio; load 2.7–7.5 s |
| `score` | 2.0–2.6 s per line (Whisper about 1.5 s, speaker 0.05–0.3 s, UTMOS 0.15–1.5 s); 4–7 s for the first after a render (model swap) |
| `transcribe` | 5.6 s for the 10.6 s reference, Whisper load included |
| `split` | 58 s for a 2:45 mp4 (about 0.35 s per second of audio, so ~10 min for 30 min) |
| `check_audio` | 0.4 s for the same mp4 |

## Memory

- One large model at a time: loading Breeze drops Whisper and the reverse
  (references released, `gc.collect()`, `mx.clear_cache()`), and the large model
  unloads after 120 s idle (footprint 4.9 GB → 0.2 GB, measured).
- The scoring models (about 450 MB loaded) stay resident between scores but are
  freed before Breeze loads; they reload in about a second.
- MLX's buffer cache is capped at 256 MB. Uncapped it held 2.2 GB next to Breeze
  4-bit and the same line took 21 s instead of 10 s.
- Peak process footprint: Breeze 8-bit 5.6 GB (6.7 GB before the scorers were
  freed for Breeze), Breeze 4-bit 4.1–5.1 GB depending on line length, Whisper +
  scorers 2.2 GB. `status` reports footprint, which counts MLX's Metal buffers;
  plain RSS stayed under 1.7 GB and hides them.
- Long uploads are decoded by ffmpeg to temporary WAVs and read 30 s at a time.
