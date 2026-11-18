"""Timeline clip edits: one piece of a rendered line, trimmed, through the voice tools (speed, pitch, warmth,
brightness, noise removal), faded and gained, written as a 24 kHz float WAV that the app plays and exports."""

import math
import os
from pathlib import Path
import subprocess
import tempfile

import numpy as np
import soundfile as sf

from . import audio
from .tts import _number

RATE = 24000          # Breeze's rate; renders are already at it
WARMTH_HZ = 200       # low shelf: body of the voice
BRIGHTNESS_HZ = 5000  # high shelf: air and sibilance
# afftdn's reduction. Its default; more leaves speech sounding watery.
DENOISE_DB = 12
# afftdn delays its output by 25 ms at 24 kHz (measured on ffmpeg 9); the chain trims that much off the start.
DENOISE_DELAY = round(0.025 * RATE)
# Silence sent after the clip, so atempo and afftdn finish its last moments instead of dropping them.
TAIL_S = 0.5


def _seconds(value, name: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not 0 <= value < math.inf:
        raise ValueError(f"{name} must be a number of seconds, 0 or more")
    return float(value)


def prepare(request: dict) -> dict:
    """Validate an edit_clip request. Raises ValueError."""
    for key in ("audio", "out"):
        if not isinstance(request.get(key), str) or not request[key]:
            raise ValueError(f"{key} (a file path) is required")
    start = _seconds(request.get("start", 0), "start")
    end = request.get("end")
    if end is not None and _seconds(end, "end") <= start:
        raise ValueError("end must be after start")
    denoise = request.get("denoise", False)
    if not isinstance(denoise, bool):
        raise ValueError("denoise must be true or false")
    return {
        "audio": request["audio"],
        "out": Path(request["out"]).expanduser(),
        "start": start,
        "end": None if end is None else float(end),
        "tempo": _number(request.get("tempo", 1), "tempo", 0.5, 2),
        "pitch": _number(request.get("pitch", 0), "pitch", -12, 12),
        "warmth": _number(request.get("warmth", 0), "warmth", -12, 12),
        "brightness": _number(request.get("brightness", 0), "brightness", -12, 12),
        "denoise": denoise,
        "gain_db": _number(request.get("gain_db", 0), "gain_db", -24, 12),
        "fade_in": _number(request.get("fade_in", 0), "fade_in", 0, 10),
        "fade_out": _number(request.get("fade_out", 0), "fade_out", 0, 10),
    }


def read(src: str) -> np.ndarray:
    """Mono samples at RATE. Renders are 24 kHz WAVs, read directly so a plain trim runs no ffmpeg."""
    path = audio._readable(src)
    try:
        samples, rate = sf.read(path, dtype="float32", always_2d=True)
        if rate == RATE:
            return samples.mean(axis=1)
    except sf.SoundFileError:
        pass
    return audio.read_mono(path, RATE)


def filters(job: dict, samples: np.ndarray, rate: int = RATE) -> str:
    """The ffmpeg filter chain for the voice tools, or "" when none is on."""
    chain = []
    if job["denoise"]:
        # The noise floor is the clip's quietest frames, kept 15 dB under its speech so a clip with no pause
        # does not have its quieter words taken for noise. afftdn accepts -80 to -20 dB.
        meter = audio.LevelMeter(rate)
        meter.add(samples)
        levels = meter.result()
        floor = max(-80.0, min(levels["noise_floor_dbfs"], levels["speech_dbfs"] - 15, -20.0))
        chain += [f"afftdn=nr={DENOISE_DB}:nf={floor:.1f}", f"atrim=start_sample={round(DENOISE_DELAY * rate / RATE)}",
                  "asetpts=PTS-STARTPTS"]
    if job["warmth"]:
        chain.append(f"lowshelf=g={job['warmth']:g}:f={WARMTH_HZ}")
    if job["brightness"]:
        chain.append(f"highshelf=g={job['brightness']:g}:f={BRIGHTNESS_HZ}")
    speed = job["tempo"]
    if job["pitch"]:
        # Playing the samples at another rate moves the pitch and the speed; atempo below undoes the speed.
        shifted = round(rate * 2 ** (job["pitch"] / 12))
        chain += [f"asetrate={shifted}", f"aresample={rate}"]
        speed *= rate / shifted
    if abs(math.log2(speed)) > 1e-6:
        # One pitch-keeping speed change, in equal atempo stages of 0.5-2x each (beyond that atempo skips audio).
        stages = max(1, math.ceil(abs(math.log2(speed)) - 1e-9))
        chain += [f"atempo={speed ** (1 / stages):.6f}"] * stages
    return ",".join(chain)


def apply(samples: np.ndarray, chain: str, rate: int = RATE) -> np.ndarray:
    run = subprocess.run(
        audio._ffmpeg("-f", "f32le", "-ar", str(rate), "-ac", "1", "-i", "pipe:0", "-af", chain,
                      "-f", "f32le", "-ar", str(rate), "-ac", "1", "pipe:1"),
        input=samples.astype(np.float32).tobytes(), capture_output=True)
    if run.returncode:
        error = run.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"ffmpeg could not apply the voice tools: {error[-300:]}")
    return np.frombuffer(run.stdout, dtype=np.float32).copy()


def fades(samples: np.ndarray, fade_in: float, fade_out: float) -> np.ndarray:
    """Raised-cosine fades (the curve of audio.fade), shortened together when they would overlap."""
    out = np.array(samples, dtype=np.float32)
    count_in, count_out = round(fade_in * RATE), round(fade_out * RATE)
    if count_in + count_out > len(out):
        scale = len(out) / (count_in + count_out)
        count_in, count_out = int(count_in * scale), int(count_out * scale)
    if count_in:
        out[:count_in] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(count_in) / count_in)
    if count_out:
        out[-count_out:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(1, count_out + 1) / count_out)
    return out


def write(path: Path, samples: np.ndarray, rate: int = RATE) -> None:
    """Into a temporary file beside `path`, then renamed, so the app never plays a half-written clip."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.stem}-", suffix=".wav")
    os.close(handle)
    try:
        sf.write(temp, samples, rate, subtype="FLOAT", format="WAV")
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


def edit_clip(request: dict, check=lambda: None) -> dict:
    """Write one edited clip. Without voice tools it is all numpy, so a trim is quick. `check` raises to cancel."""
    job = prepare(request)
    source = read(job["audio"])
    end = len(source) if job["end"] is None else min(len(source), round(job["end"] * RATE))
    samples = source[round(job["start"] * RATE):end]
    if not len(samples):
        raise ValueError(f"Nothing left after trimming: the audio is {len(source) / RATE:.3f} s long")
    chain = filters(job, samples)
    if chain:
        check()
        # Cut to the exact new length, so the duration is always (end - start) / tempo.
        length = round(len(samples) / job["tempo"])
        samples = apply(np.concatenate([samples, np.zeros(round(TAIL_S * RATE), np.float32)]), chain)[:length]
        if not len(samples):
            raise ValueError("The clip is too short for these voice tools")
    # Fades and gain come last, so fade lengths are seconds of the output, after any speed change.
    samples = fades(samples, job["fade_in"], job["fade_out"]) * np.float32(10 ** (job["gain_db"] / 20))
    samples = np.clip(samples, -1, 1)
    check()
    write(job["out"], samples)
    return {"path": str(job["out"]), "duration": round(len(samples) / RATE, 3)}
