"""Decoding with ffmpeg, level checks, and small signal helpers."""

from pathlib import Path
import shutil
import subprocess

import numpy as np

FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
CHECK_RATE = 48000

# Thresholds behind the check_audio warnings (see PROTOCOL.md).
QUIET_SPEECH_DBFS = -35.0
CLIPPED_RATIO = 0.0001
CLIP_LEVEL = 0.99
NOISY_FLOOR_DBFS = -50.0


def _ffmpeg(*args: str) -> list[str]:
    return [FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *args]


def _readable(src) -> str:
    path = Path(src).expanduser()
    if not path.is_file():
        raise ValueError(f"File not found: {path}")
    return str(path)


def decode(src, outputs: dict[str, int | None]) -> None:
    """Decode the first audio stream of any ffmpeg-readable file (audio or video)
    to mono 16-bit WAVs in one pass. `outputs` maps a WAV path to a sample rate,
    or None to keep the source rate."""
    cmd = _ffmpeg("-i", _readable(src))
    for path, rate in outputs.items():
        cmd += ["-map", "0:a:0", "-vn", "-ac", "1"]
        if rate:
            cmd += ["-ar", str(rate)]
        cmd += ["-c:a", "pcm_s16le", str(path)]
    run = subprocess.run(cmd, capture_output=True, text=True)
    if run.returncode:
        raise ValueError(f"Could not read audio from {src}: {run.stderr.strip()[-300:]}")


def read_mono(src, rate: int = 16000, start: float | None = None, end: float | None = None) -> np.ndarray:
    """Return float32 mono samples at `rate`, optionally only start..end seconds.
    For short files (renders, references); long files go through decode()."""
    cmd = _ffmpeg()
    if start:
        cmd += ["-ss", f"{start:.3f}"]
    cmd += ["-i", _readable(src)]
    if end is not None:
        cmd += ["-t", f"{end - (start or 0):.3f}"]
    cmd += ["-map", "0:a:0", "-vn", "-ac", "1", "-ar", str(rate), "-f", "f32le", "-"]
    run = subprocess.run(cmd, capture_output=True)
    if run.returncode:
        raise ValueError(f"Could not read audio from {src}: {run.stderr.decode(errors='replace').strip()[-300:]}")
    return np.frombuffer(run.stdout, dtype=np.float32).copy()


def loudnorm(src: Path, dst: Path, lufs: float, rate: int) -> None:
    subprocess.run(
        _ffmpeg("-i", str(src), "-af", f"loudnorm=I={lufs}:TP=-1.5:LRA=7", "-ar", str(rate), str(dst)),
        check=True, capture_output=True,
    )


def trim_outer_silence(audio: np.ndarray, rate: int) -> np.ndarray:
    """Ported from directed_voice.py."""
    audible = np.flatnonzero(np.abs(audio) > max(0.002, np.max(np.abs(audio)) * 0.005))
    if not len(audible):
        return audio
    padding = round(0.08 * rate)
    return audio[max(0, audible[0] - padding):min(len(audio), audible[-1] + padding + 1)]


def quietest(samples: np.ndarray, rate: int, frame_s: float = 0.02, smooth: int = 5) -> int:
    """Sample index in the quietest stretch: 20 ms frame energy averaged over 100 ms,
    so the pick lands inside a real pause rather than a dip within a word."""
    frame = max(1, int(rate * frame_s))
    count = len(samples) // frame
    if count < 2:
        return len(samples) // 2
    energy = np.mean(samples[:count * frame].reshape(count, frame) ** 2, axis=1)
    offset = 0
    if count >= smooth:
        energy = np.convolve(energy, np.ones(smooth) / smooth, mode="valid")
        offset = smooth // 2
    return (int(np.argmin(energy)) + offset) * frame + frame // 2


def _db(value: float) -> float:
    return round(20 * np.log10(max(value, 1e-10)), 1)


class LevelMeter:
    """Streaming level statistics over 50 ms frames."""

    def __init__(self, rate: int):
        self.rate = rate
        self.frame = rate // 20
        self.carry = np.zeros(0, dtype=np.float32)
        self.count = 0
        self.peak = 0.0
        self.squares = 0.0
        self.clipped = 0
        self.frame_rms: list[float] = []

    def add(self, block: np.ndarray) -> None:
        if not len(block):
            return
        self.count += len(block)
        self.peak = max(self.peak, float(np.max(np.abs(block))))
        self.squares += float(np.dot(block, block))
        self.clipped += int(np.count_nonzero(np.abs(block) >= CLIP_LEVEL))
        data = np.concatenate([self.carry, block])
        whole = len(data) // self.frame * self.frame
        if whole:
            frames = data[:whole].reshape(-1, self.frame)
            self.frame_rms.extend(np.sqrt(np.mean(frames * frames, axis=1)).tolist())
        self.carry = data[whole:]

    def result(self) -> dict:
        if not self.count:
            raise ValueError("The file contains no audio")
        rms = np.array(self.frame_rms or [np.sqrt(self.squares / self.count)])
        noise_floor = _db(float(np.percentile(rms, 10)))
        speech = _db(float(np.percentile(rms, 95)))
        ratio = self.clipped / self.count
        warnings = []
        if speech < QUIET_SPEECH_DBFS:
            warnings.append("quiet")
        if ratio >= CLIPPED_RATIO:
            warnings.append("clipped")
        if noise_floor > NOISY_FLOOR_DBFS:
            warnings.append("noisy")
        return {
            "duration": round(self.count / self.rate, 3),
            "peak_dbfs": _db(self.peak),
            "rms_dbfs": _db(np.sqrt(self.squares / self.count)),
            "speech_dbfs": speech,
            "noise_floor_dbfs": noise_floor,
            "clipping_ratio": round(ratio, 6),
            "warnings": warnings,
        }


def check_audio(src) -> dict:
    """Level check for a recording or upload, streamed so long files stay small in memory."""
    cmd = _ffmpeg("-i", _readable(src), "-map", "0:a:0", "-vn", "-ac", "1",
                  "-ar", str(CHECK_RATE), "-f", "f32le", "-")
    meter = LevelMeter(CHECK_RATE)
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as proc:
        while chunk := proc.stdout.read(CHECK_RATE * 4 * 10):
            meter.add(np.frombuffer(chunk[:len(chunk) // 4 * 4], dtype=np.float32))
        error = proc.stderr.read().decode(errors="replace").strip()
    if proc.returncode:
        raise ValueError(f"Could not read audio from {src}: {error[-300:]}")
    return meter.result()
