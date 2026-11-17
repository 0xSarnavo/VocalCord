#!/usr/bin/env python3
"""Generate an offline WAV in your voice with LuxTTS."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description="Clone your voice for a video narration")
    parser.add_argument("--reference", type=Path, required=True, help="3+ seconds of clean speech in your voice")
    parser.add_argument("--text", help="Text to speak")
    parser.add_argument("--text-file", type=Path, help="UTF-8 script file")
    parser.add_argument("--output", type=Path, required=True, help="Output WAV path")
    parser.add_argument("--steps", type=int, default=4, help="Sampling steps (default: 4)")
    parser.add_argument("--reference-seconds", type=float, default=12, help="Maximum reference speech to use (default: 12 seconds)")
    parser.add_argument("--rms", type=float, default=0.1, help="Reference loudness target (default: 0.1)")
    parser.add_argument("--lufs", type=float, default=-16, help="Output loudness in LUFS (default: -16)")
    args = parser.parse_args()

    if not args.reference.is_file():
        parser.error(f"Reference audio not found: {args.reference}")
    if bool(args.text) == bool(args.text_file):
        parser.error("Provide exactly one of --text or --text-file")
    if args.text_file and not args.text_file.is_file():
        parser.error(f"Script file not found: {args.text_file}")
    if args.steps < 1:
        parser.error("--steps must be positive")
    if args.reference_seconds < 3 or args.reference_seconds > 30:
        parser.error("--reference-seconds must be between 3 and 30")
    if args.rms <= 0 or args.rms > 0.3:
        parser.error("--rms must be greater than 0 and at most 0.3")
    if args.lufs < -30 or args.lufs > -10:
        parser.error("--lufs must be between -30 and -10")
    if shutil.which("ffmpeg") is None:
        parser.error("ffmpeg is required to set the output volume")
    text = args.text_file.read_text(encoding="utf-8").strip() if args.text_file else args.text.strip()
    if not text:
        parser.error("The script is empty")

    # The one-time setup downloads both LuxTTS and its Whisper transcriber.
    # Every render after that must use the local cache, with no network check.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"

    try:
        import soundfile as sf
        from zipvoice.luxvoice import LuxTTS
    except ImportError as error:
        parser.error(f"LuxTTS is not installed in this Python environment: {error}. See README.md")

    try:
        duration = sf.info(str(args.reference)).duration
    except Exception as error:
        parser.error(f"Cannot read the reference audio: {error}")
    if duration < 3:
        parser.error(f"Reference audio is only {duration:.1f} seconds; record at least 3 seconds")

    model = LuxTTS("YatharthS/LuxTTS", device="mps")
    prompt = model.encode_prompt(str(args.reference), duration=min(duration, args.reference_seconds), rms=args.rms)
    audio = model.generate_speech(text, prompt, num_steps=args.steps)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent) as temporary:
        raw_output = Path(temporary) / "raw.wav"
        normalized_output = Path(temporary) / "normalized.wav"
        sf.write(str(raw_output), audio.numpy().squeeze(), 48000)
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(raw_output),
             "-af", f"loudnorm=I={args.lufs}:TP=-1.5:LRA=7", "-ar", "48000", str(normalized_output)],
            check=True,
        )
        os.replace(normalized_output, args.output)
    print(args.output.resolve())


if __name__ == "__main__":
    main()
