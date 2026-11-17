"""Breeze TTS 2 rendering, ported from directed_voice.py.

A render is a list of lines. Each line has its own voice (reference audio and its
exact transcript, optional breath recording and pronunciations), a tone, a pause
after it, and an optional seed. Inline tags work as in directed_voice.py:
`[pause 0.30]`, `[breath]`, and `[tone]` or `[free direction]` mid-line.
"""

import json
import os
from pathlib import Path
import re
import tempfile

import numpy as np
import soundfile as sf

from . import audio

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

MODELS = {
    "8bit": ("~/voice/models/Breeze-TTS-2-mlx-8bit", "mlx-community/Breeze-TTS-2-mlx-8bit"),
    "4bit": ("~/voice/models/Breeze-TTS-2-mlx-4bit", "mlx-community/Breeze-TTS-2-mlx-4bit"),
}
DEFAULT_SEED = 7


def resolve_model(name: str) -> str:
    """'8bit' / '4bit' (local copy under ~/voice/models, else the Hugging Face repo) or a path."""
    if name in MODELS:
        local, repo = MODELS[name]
        local = Path(local).expanduser()
        return str(local) if local.is_dir() else repo
    path = Path(name).expanduser()
    if not path.is_dir():
        raise ValueError(f"Model directory not found: {path}")
    return str(path)


def resolve_tone(tone: str | None) -> str:
    tone = (tone or "neutral").strip()
    return STYLES.get(tone.lower(), tone) or STYLES["neutral"]


def apply_pronunciations(text: str, pronunciations: dict[str, str] | None) -> str:
    """Replace whole words (case-insensitive) with their respelling, longest first."""
    for word in sorted(pronunciations or {}, key=len, reverse=True):
        spoken = pronunciations[word]
        text = re.sub(rf"(?<!\w){re.escape(word)}(?!\w)", lambda _: spoken, text, flags=re.IGNORECASE)
    return text


def parse_line(text: str, tone: str | None = None) -> list[tuple[str, object, str]]:
    """Split one line into ("speech", text, instruction), ("pause", seconds, "")
    and ("breath", 0.0, "") items. Ported from directed_voice.parse_script."""
    items = []
    instruction = resolve_tone(tone)
    for part in re.split(r"(\[[^]]+\])", text.strip()):
        if not part:
            continue
        if part.startswith("[") and part.endswith("]"):
            label = part[1:-1].strip()
            pause = re.fullmatch(r"pause\s+(\d+(?:\.\d+)?)", label, re.I)
            if pause:
                seconds = float(pause.group(1))
                if seconds > 10:
                    raise ValueError("A pause must be at most 10 seconds")
                items.append(("pause", seconds, ""))
            elif label.lower() == "breath":
                items.append(("breath", 0.0, ""))
            elif label.lower().startswith("pause"):
                raise ValueError("Write pauses as [pause 0.30]")
            else:
                instruction = resolve_tone(label)
        elif part.strip():
            items.append(("speech", part.strip(), instruction))
    return items


def _number(value, name: str, low: float, high: float) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not low <= value <= high:
        raise ValueError(f"{name} must be a number from {low:g} to {high:g}")
    return float(value)


def prepare(request: dict) -> dict:
    """Validate a render request and parse its lines. Raises ValueError."""
    output = request.get("output")
    if not output:
        raise ValueError("output is required")
    lines = request.get("lines")
    if not isinstance(lines, list) or not lines:
        raise ValueError("lines must be a non-empty list")
    parsed = []
    for number, line in enumerate(lines, 1):
        try:
            if not isinstance(line, dict) or not isinstance(line.get("text"), str):
                raise ValueError("each line needs text")
            voice = line.get("voice") or {}
            reference = Path(str(voice.get("audio", ""))).expanduser()
            transcript = str(voice.get("text", "")).strip()
            if not reference.is_file():
                raise ValueError(f"voice audio not found: {reference}")
            if not transcript:
                raise ValueError("voice text (the reference transcript) is empty")
            items = parse_line(line["text"], line.get("tone"))
            if not any(kind == "speech" for kind, _, _ in items):
                raise ValueError("no spoken text")
            breath = voice.get("breath")
            if any(kind == "breath" for kind, _, _ in items):
                if not breath or not Path(breath).expanduser().is_file():
                    raise ValueError("[breath] needs voice.breath, a short recording of an inhale")
            pronunciations = voice.get("pronunciations") or {}
            items = [(kind, apply_pronunciations(value, pronunciations) if kind == "speech" else value, instruction)
                     for kind, value, instruction in items]
            seed = line.get("seed")
            if seed is not None and (not isinstance(seed, int) or isinstance(seed, bool)):
                raise ValueError("seed must be an integer")
            parsed.append({
                "text": line["text"],
                "items": items,
                "reference": str(reference),
                "transcript": transcript,
                "breath": str(Path(breath).expanduser()) if breath else None,
                "pause_after": _number(line.get("pause_after", 0), "pause_after", 0, 10),
                "seed": seed,
            })
        except ValueError as error:
            raise ValueError(f"Line {number}: {error}") from None
    return {
        "lines": parsed,
        "model": resolve_model(str(request.get("model", "8bit"))),
        "cfg_scale": _number(request.get("cfg_scale", 4), "cfg_scale", 1, 6),
        "lufs": _number(request.get("lufs", -16), "lufs", -30, -10),
        "output": Path(output).expanduser(),
    }


def _load_breath(path: str, rate: int) -> np.ndarray:
    breath, breath_rate = sf.read(path, dtype="float32")
    if breath.ndim == 2:
        breath = breath.mean(axis=1)
    if not 0.05 <= len(breath) / breath_rate <= 2:
        raise ValueError("The breath recording must be 0.05 to 2 seconds long")
    if breath_rate != rate:
        breath = np.interp(
            np.arange(round(len(breath) * rate / breath_rate)) / rate,
            np.arange(len(breath)) / breath_rate,
            breath,
        ).astype(np.float32)
    return breath


def render(model, job: dict, progress=lambda **_: None, check=lambda: None) -> dict:
    """Render a prepared job with a loaded Breeze model. `check` raises to cancel;
    it runs before each line and before the files are written, so a cancelled
    render leaves nothing behind."""
    rate = model.sample_rate
    pieces, timing, breaths = [], [], {}
    elapsed = 0.0
    segment = 0
    total = len(job["lines"])
    for index, line in enumerate(job["lines"]):
        check()
        start = None
        for kind, value, instruction in line["items"]:
            if kind == "pause":
                piece = np.zeros(round(value * rate), dtype=np.float32)
            elif kind == "breath":
                if line["breath"] not in breaths:
                    breaths[line["breath"]] = _load_breath(line["breath"], rate)
                piece = breaths[line["breath"]]
            else:
                seed = (line["seed"] if line["seed"] is not None else DEFAULT_SEED + index) + segment
                chunks = model.generate(
                    text=value,
                    instruct=instruction,
                    ref_audio=line["reference"],
                    ref_text=line["transcript"],
                    cfg_scale=job["cfg_scale"],
                    seed=seed,
                )
                piece = audio.trim_outer_silence(
                    np.concatenate([np.asarray(chunk.audio, dtype=np.float32) for chunk in chunks]), rate)
                segment += 1
            if start is None:
                start = elapsed
            pieces.append(piece)
            elapsed += len(piece) / rate
        segment = 0
        timing.append({
            "index": index,
            "text": line["text"],
            "spoken": " ".join(str(value) for kind, value, _ in line["items"] if kind == "speech"),
            "start": round(start, 3),
            "end": round(elapsed, 3),
        })
        if line["pause_after"] and index < total - 1:
            pieces.append(np.zeros(round(line["pause_after"] * rate), dtype=np.float32))
            elapsed += line["pause_after"]
        progress(stage="render", done=index + 1, total=total, line=timing[-1])

    output = job["output"]
    timing_path = output.with_suffix(".json")
    check()
    output.parent.mkdir(parents=True, exist_ok=True)
    # Both files are made in a temporary folder, which is deleted on cancel or failure.
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        raw = Path(temp) / "raw.wav"
        normalized = Path(temp) / "normalized.wav"
        timing_temp = Path(temp) / "timing.json"
        sf.write(raw, np.concatenate(pieces), rate)
        audio.loudnorm(raw, normalized, job["lufs"], rate)
        timing_temp.write_text(json.dumps(timing, indent=2) + "\n", encoding="utf-8")
        check()
        os.replace(normalized, output)
        os.replace(timing_temp, timing_path)
    return {
        "path": str(output),
        "timing_path": str(timing_path),
        "duration": round(elapsed, 3),
        "sample_rate": rate,
        "lines": timing,
    }
