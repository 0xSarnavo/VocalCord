#!/usr/bin/env python3
"""Render a line-directed voice script with a local Breeze TTS 2 model."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import numpy as np
import soundfile as sf


STYLES = {
    "neutral": "Speak naturally at a relaxed conversational pace.",
    "confident": "Speak with quiet confidence, a steady pace, and firm natural emphasis. Do not sound theatrical.",
    "sad": "Speak softly and more slowly with restrained sadness. Sound natural, without crying.",
    "happy": "Speak with warm, genuine happiness and a brighter, slightly quicker delivery. Do not overact.",
    "angry": "Speak with controlled anger and firm emphasis. Keep the words clear, without shouting.",
    "soft": "Speak gently and quietly, with a close conversational delivery.",
    "slow": "Speak clearly at a measured, slower pace, with natural pauses.",
    "hesitant": "Speak naturally with occasional small hesitations and thoughtful pauses. Keep the words intelligible.",
}


def parse_script(path: Path) -> list[tuple[str, str | float, str]]:
    items = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        row = raw.strip()
        if not row or row.startswith("#"):
            continue
        instruction = STYLES["neutral"]
        for part in re.split(r"(\[[^]]+\])", row):
            if not part:
                continue
            if part.startswith("[") and part.endswith("]"):
                label = part[1:-1].strip()
                pause = re.fullmatch(r"pause\s+(\d+(?:\.\d+)?)", label, re.I)
                if pause:
                    seconds = float(pause.group(1))
                    if seconds > 10:
                        raise ValueError(f"Line {number}: pause must be at most 10 seconds")
                    items.append(("pause", seconds, ""))
                elif label.lower() == "breath":
                    items.append(("breath", 0.0, ""))
                elif label.lower().startswith("pause"):
                    raise ValueError(f"Line {number}: use [pause 0.30]")
                else:
                    instruction = STYLES.get(label.lower(), label)
            elif part.strip():
                items.append(("speech", part.strip(), instruction))
    if not any(item[0] == "speech" for item in items):
        raise ValueError("The script contains no spoken lines")
    return items


def trim_outer_silence(audio: np.ndarray, rate: int) -> np.ndarray:
    audible = np.flatnonzero(np.abs(audio) > max(0.002, np.max(np.abs(audio)) * 0.005))
    if not len(audible):
        return audio
    padding = round(0.08 * rate)
    return audio[max(0, audible[0] - padding):min(len(audio), audible[-1] + padding + 1)]


def render(items, model, rate, breath, reference, reference_text, args, output, style=None, reference_map=None):
    pieces = []
    marks = []
    elapsed = 0.0
    for kind, value, instruction in items:
        if kind == "pause":
            pieces.append(np.zeros(round(value * rate), dtype=np.float32))
            elapsed += value
            continue
        if kind == "breath":
            pieces.append(breath)
            elapsed += len(breath) / rate
            continue
        direction = STYLES[style] if style else instruction
        reference_for_line = reference
        text_for_line = reference_text
        if reference_map:
            style_name = style or next((name for name, prompt in STYLES.items() if prompt == instruction), None)
            if style_name in reference_map:
                reference_for_line, text_for_line = reference_map[style_name]
        chunks = model.generate(
            text=value,
            instruct=direction,
            ref_audio=str(reference_for_line),
            ref_text=text_for_line,
            cfg_scale=args.cfg_scale,
            seed=args.seed + len(marks),
        )
        audio = trim_outer_silence(np.concatenate([np.asarray(chunk.audio, dtype=np.float32) for chunk in chunks]), rate)
        pieces.append(audio)
        end = elapsed + len(audio) / rate
        marks.append({"text": value, "direction": direction, "start": round(elapsed, 3), "end": round(end, 3)})
        elapsed = end
        print(f"{marks[-1]['start']:.2f}-{marks[-1]['end']:.2f}  {value}", flush=True)

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        raw = Path(temp) / "raw.wav"
        normalized = Path(temp) / "normalized.wav"
        sf.write(raw, np.concatenate(pieces), rate)
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(raw),
             "-af", f"loudnorm=I={args.lufs}:TP=-1.5:LRA=7", "-ar", str(rate), str(normalized)],
            check=True,
        )
        os.replace(normalized, output)
    output.with_suffix(".json").write_text(json.dumps(marks, indent=2) + "\n", encoding="utf-8")
    print(output.resolve(), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Clone and direct each line of a video voice script")
    parser.add_argument("--script", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--reference-text-file", type=Path, required=True)
    parser.add_argument("--breath-audio", type=Path, help="Optional short WAV to insert at [breath] tags")
    parser.add_argument("--reference-map", type=Path, help="JSON map of speaking styles to saved reference takes")
    parser.add_argument("--compare-reference", type=Path, help="Second reference to compare with the current one")
    parser.add_argument("--compare-reference-text-file", type=Path)
    parser.add_argument("--model", type=Path, default=Path.home() / "voice/models/Breeze-TTS-2-mlx-8bit")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--all-styles", action="store_true", help="Render neutral, confident, sad and happy versions from one model load")
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--cfg-scale", type=float, default=4)
    parser.add_argument("--lufs", type=float, default=-16)
    args = parser.parse_args()

    for path in (args.script, args.reference, args.reference_text_file):
        if not path.is_file():
            parser.error(f"File not found: {path}")
    if not args.model.is_dir():
        parser.error(f"Model directory not found: {args.model}")
    if args.breath_audio and not args.breath_audio.is_file():
        parser.error(f"Breath recording not found: {args.breath_audio}")
    if bool(args.compare_reference) != bool(args.compare_reference_text_file):
        parser.error("--compare-reference needs --compare-reference-text-file")
    if args.compare_reference and (args.all_styles or args.reference_map):
        parser.error("Reference comparison cannot be combined with style comparison or a reference map")
    for path in (args.compare_reference, args.compare_reference_text_file, args.reference_map):
        if path and not path.is_file():
            parser.error(f"File not found: {path}")
    if shutil.which("ffmpeg") is None:
        parser.error("ffmpeg is required to set output volume")
    if not 1 <= args.cfg_scale <= 6:
        parser.error("--cfg-scale must be between 1 and 6")
    if not -30 <= args.lufs <= -10:
        parser.error("--lufs must be between -30 and -10")
    try:
        items = parse_script(args.script)
    except ValueError as error:
        parser.error(str(error))
    if any(kind == "breath" for kind, _, _ in items) and not args.breath_audio:
        parser.error("[breath] needs --breath-audio with a short recording of your inhale")
    reference_text = args.reference_text_file.read_text(encoding="utf-8").strip()
    if not reference_text:
        parser.error("The reference transcript is empty")
    reference_map = {}
    if args.reference_map:
        try:
            data = json.loads(args.reference_map.read_text(encoding="utf-8"))
            for name, entry in data.items():
                if name not in STYLES or not isinstance(entry, dict):
                    raise ValueError(f"Unknown style in reference map: {name}")
                path = Path(entry["audio"])
                transcript = entry["text"].strip()
                if not path.is_file() or not transcript:
                    raise ValueError(f"Invalid reference for {name}")
                reference_map[name] = (path, transcript)
        except (ValueError, KeyError, TypeError) as error:
            parser.error(f"Invalid reference map: {error}")

    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    from mlx_audio.tts import load

    model = load(str(args.model))
    rate = model.sample_rate
    breath = None
    if args.breath_audio:
        breath, breath_rate = sf.read(args.breath_audio, dtype="float32")
        if breath.ndim == 2:
            breath = breath.mean(axis=1)
        if not 0.05 <= len(breath) / breath_rate <= 2:
            parser.error("The breath recording must be 0.05 to 2 seconds long")
        if breath_rate != rate:
            breath = np.interp(
                np.arange(round(len(breath) * rate / breath_rate)) / rate,
                np.arange(len(breath)) / breath_rate,
                breath,
            ).astype(np.float32)
    if args.all_styles:
        for style in ("neutral", "confident", "sad", "happy"):
            output = args.output.with_name(f"{args.output.stem}-{style}.wav")
            print(f"Rendering {style}…", flush=True)
            render(items, model, rate, breath, args.reference, reference_text, args, output, style, reference_map)
    elif args.compare_reference:
        other_text = args.compare_reference_text_file.read_text(encoding="utf-8").strip()
        if not other_text:
            parser.error("The comparison transcript is empty")
        for suffix, audio, transcript in (("current", args.reference, reference_text),
                                          ("new", args.compare_reference, other_text)):
            output = args.output.with_name(f"{args.output.stem}-{suffix}.wav")
            print(f"Rendering {suffix} reference…", flush=True)
            render(items, model, rate, breath, audio, transcript, args, output)
    else:
        render(items, model, rate, breath, args.reference, reference_text, args, args.output, reference_map=reference_map)


if __name__ == "__main__":
    main()
