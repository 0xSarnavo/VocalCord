"""Export: rendered lines joined with their pauses, loudness-normalised, written as
WAV or M4A, with optional per-line and per-voice files, SRT captions and timing JSON."""

import itertools
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile

import numpy as np
import soundfile as sf

from . import audio
from .tts import _number

RATE = 24000          # Breeze's rate; renders are already at it
FORMATS = ("wav", "m4a")


def prepare(request: dict) -> dict:
    """Validate a mix request. Raises ValueError."""
    out_dir, name = request.get("out_dir"), request.get("name")
    if not isinstance(out_dir, str) or not out_dir:
        raise ValueError("out_dir is required")
    if not isinstance(name, str) or not name.strip():
        raise ValueError("name is required")
    fmt = request.get("format", "wav")
    if fmt not in FORMATS:
        raise ValueError("format must be wav or m4a")
    lines = request.get("lines")
    if not isinstance(lines, list) or not lines:
        raise ValueError("lines must be a non-empty list")
    parsed = []
    for index, line in enumerate(lines):
        if not isinstance(line, dict) or not isinstance(line.get("audio"), str) or not isinstance(line.get("text"), str):
            raise ValueError(f"Line {index + 1}: audio and text are required")
        number = line.get("number", index + 1)
        if not isinstance(number, int) or isinstance(number, bool):
            raise ValueError(f"Line {index + 1}: number must be an integer")
        parsed.append({"audio": line["audio"], "text": line["text"], "number": number,
                       "voice": str(line.get("voice") or "Voice"),
                       "pause_after": _number(line.get("pause_after", 0), "pause_after", 0, 10)})
    return {
        "out_dir": Path(out_dir).expanduser(),
        # A file name, not a path: no slashes or colons, no leading dot.
        "name": re.sub(r"[/:\\]", "-", name).strip(" .") or "Export",
        "format": fmt,
        "lufs": _number(request.get("lufs", -16), "lufs", -30, -10),
        "lines": parsed,
        **{option: bool(request.get(option)) for option in ("per_line", "per_voice", "srt", "timing")},
    }


def file_names(job: dict, stem: str) -> dict:
    """Every file an export writes, by role. The mix is "main"."""
    ext = job["format"]
    names = {"main": f"{stem}.{ext}"}
    if job["per_line"]:
        names |= {role: f"{stem} {role}.{ext}" for role in line_roles(job)}
    if job["per_voice"]:
        names |= {f"voice {voice}": f"{stem} {_safe(voice)}.{ext}" for voice in voices(job)}
    if job["srt"]:
        names["srt"] = f"{stem}.srt"
    if job["timing"]:
        names["timing"] = f"{stem}.json"
    return names


def unique_stem(job: dict) -> str:
    """The name, else "name 2", "name 3"…, so that no file of this export exists yet."""
    for count in itertools.count(1):
        stem = job["name"] if count == 1 else f"{job['name']} {count}"
        if not any((job["out_dir"] / name).exists() for name in file_names(job, stem).values()):
            return stem


def runs(job: dict) -> list[list[int]]:
    """Line indexes grouped into script lines. The timeline sends one entry per clip, so a line cut into pieces
    arrives as consecutive entries with the same number; captions, timing and per-line files treat them as one."""
    return [[index for index, _ in group]
            for _, group in itertools.groupby(enumerate(job["lines"]), key=lambda item: item[1]["number"])]


def line_roles(job: dict) -> list[str]:
    """A role per run: "line 3", then "line 3 (2)" when line 3 comes back later (a piece moved elsewhere),
    so no per-line file overwrites another."""
    seen: dict[int, int] = {}
    roles = []
    for run in runs(job):
        number = job["lines"][run[0]]["number"]
        seen[number] = seen.get(number, 0) + 1
        roles.append(f"line {number}" + (f" ({seen[number]})" if seen[number] > 1 else ""))
    return roles


def voices(job: dict) -> list[str]:
    return list(dict.fromkeys(line["voice"] for line in job["lines"]))


def _safe(name: str) -> str:
    return re.sub(r"[/:\\]", "-", name).strip(" .") or "Voice"


def caption(text: str) -> str:
    """Script text without [tags] or (cues)."""
    return " ".join(re.sub(r"\[[^\]]*\]|\([^)]*\)", " ", text).split())


def srt(timing: list[dict]) -> str:
    def stamp(seconds: float) -> str:
        ms = round(seconds * 1000)
        return f"{ms // 3_600_000:02}:{ms // 60_000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"

    cues = [(line, caption(line["text"])) for line in timing]
    cues = [(line, text) for line, text in cues if text]
    return "\n".join(f"{number}\n{stamp(line['start'])} --> {stamp(line['end'])}\n{text}\n"
                     for number, (line, text) in enumerate(cues, 1))


def measure(path: Path, lufs: float = -16) -> dict:
    """ffmpeg loudnorm's first-pass measurements (input_i, input_tp, ...) as strings."""
    run = subprocess.run([audio.FFMPEG, "-hide_banner", "-nostdin", "-i", str(path), "-af",
                          f"loudnorm=I={lufs}:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"],
                         capture_output=True, text=True)
    if run.returncode or "{" not in run.stderr:
        raise ValueError(f"Could not measure loudness of {path}: {run.stderr.strip()[-300:]}")
    return json.loads(run.stderr[run.stderr.rindex("{"):run.stderr.rindex("}") + 1])


def normalize(src: Path, dst: Path, lufs: float) -> None:
    """Two-pass loudnorm: measure, then apply as a plain gain where the true peak allows."""
    m = measure(src, lufs)
    if not math.isfinite(float(m["input_i"])):      # silence: nothing to normalise
        sf.write(dst, sf.read(src, dtype="float32")[0], RATE, subtype="FLOAT")
        return
    applied = (f"loudnorm=I={lufs}:TP=-1.5:LRA=11:measured_I={m['input_i']}:measured_TP={m['input_tp']}:"
               f"measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:offset={m['target_offset']}:linear=true")
    subprocess.run(audio._ffmpeg("-i", str(src), "-af", applied, "-ar", str(RATE), "-c:a", "pcm_f32le", str(dst)),
                   check=True, capture_output=True)


def _write(path: Path, samples: np.ndarray, fmt: str) -> None:
    if fmt == "wav":
        sf.write(path, samples, RATE, subtype="PCM_16")
        return
    wav = path.with_suffix(".tmp.wav")
    sf.write(wav, samples, RATE, subtype="FLOAT")
    subprocess.run(audio._ffmpeg("-i", str(wav), "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", str(path)),
                   check=True, capture_output=True)
    wav.unlink()


def mix(request: dict, progress=lambda **_: None, check=lambda: None) -> dict:
    """Write an export. `check` raises to cancel; nothing is left behind when it does."""
    job = prepare(request)
    pieces, spans, elapsed = [], [], 0.0
    for index, line in enumerate(job["lines"]):
        check()
        samples = audio.read_mono(line["audio"], RATE)
        pieces.append(samples)
        spans.append((round(elapsed, 3), round(elapsed + len(samples) / RATE, 3)))
        elapsed += len(samples) / RATE
        if line["pause_after"] and index < len(job["lines"]) - 1:
            pieces.append(np.zeros(round(line["pause_after"] * RATE), dtype=np.float32))
            elapsed += len(pieces[-1]) / RATE
        progress(stage="read", done=index + 1, total=len(job["lines"]))
    # A split line runs from its first piece's start to its last piece's end, the gaps between them included.
    timing = []
    for run in runs(job):
        first = job["lines"][run[0]]
        timing.append({"index": run[0], "number": first["number"], "text": first["text"], "voice": first["voice"],
                       "start": spans[run[0]][0], "end": spans[run[-1]][1]})

    out_dir = job["out_dir"]
    out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=out_dir) as temp:
        temp = Path(temp)
        sf.write(temp / "raw.wav", np.concatenate(pieces), RATE, subtype="FLOAT")
        check()
        progress(stage="normalize")
        normalize(temp / "raw.wav", temp / "normalized.wav", job["lufs"])
        mixed = sf.read(temp / "normalized.wav", dtype="float32")[0]
        stem = unique_stem(job)
        names = file_names(job, stem)

        def span(line):
            return slice(round(line["start"] * RATE), round(line["end"] * RATE))

        audio_files = {"main": mixed}
        if job["per_line"]:
            audio_files |= {role: mixed[span(line)] for role, line in zip(line_roles(job), timing)}
        if job["per_voice"]:
            for voice in voices(job):
                # The whole timeline with only this voice's lines, so stems line up with the mix.
                stem_audio = np.zeros_like(mixed)
                for line in timing:
                    if line["voice"] == voice:
                        stem_audio[span(line)] = mixed[span(line)]
                audio_files[f"voice {voice}"] = stem_audio
        progress(stage="write")
        for role, samples in audio_files.items():
            check()
            _write(temp / names[role], samples, job["format"])
        if job["srt"]:
            (temp / names["srt"]).write_text(srt(timing), encoding="utf-8")
        if job["timing"]:
            (temp / names["timing"]).write_text(json.dumps(timing, indent=2) + "\n", encoding="utf-8")
        check()
        for name in names.values():
            os.replace(temp / name, out_dir / name)

    main = out_dir / names["main"]
    loudness = float(measure(main, job["lufs"])["input_i"])
    return {
        "path": str(main),
        "files": [str(out_dir / name) for name in names.values()],
        "duration": round(elapsed, 3),
        "lufs": round(loudness, 1) if math.isfinite(loudness) else None,
        "lines": timing,
    }
