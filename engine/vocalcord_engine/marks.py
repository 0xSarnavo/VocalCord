"""Script marks applied to a rendered line after rendering: pauses, a part played slower or faster, and stress (a
small lift in level and pitch). Marks point at tokens, the line's words as the app splits them, through their word
times (from score or time_words). Writes a float WAV at the source's rate, the way edit_clip does."""

from pathlib import Path

import numpy as np
import soundfile as sf

from . import align, audio, edit
from .tts import _number

# A cut point between two words is in the quietest 20 ms between them, looking this far into each word.
REACH_S = 0.05
CUT_FRAME_S = 0.02
# Frames this close to the quietest one count as the same pause, and the cut goes in its middle.
QUIET_DB = 6.0
# Fades either side of an inserted silence, so a cut in a dip between words does not click.
PAUSE_FADE_S = 0.005
# Equal-power crossfades where a part at another speed or pitch joins the rest.
CROSSFADE_S = 0.01
# Stress, the "small lift": a little louder and a little higher, the same length.
STRESS_DB = 2.0
STRESS_RAMP_S = 0.03
STRESS_SEMITONES = 0.3
# ffmpeg's atempo puts its output about 9 ms early (measured at 16-48 kHz, 0.5-2x). This much silence goes in front,
# so a changed part lines up with the original at the joins and with its word times.
ATEMPO_LEAD_S = 0.009
KINDS = ("pauses", "speeds", "stresses")


def _seconds(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value < float("inf")


def _index(value, name: str, low: int, high: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
        raise ValueError(f"{name} must be a token index from {low} to {high}")
    return value


def _items(marks: dict, kind: str) -> list[dict]:
    items = marks.get(kind)
    if items is None:
        return []
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        raise ValueError(f"marks.{kind} must be a list of objects")
    return items


def _span(item: dict, name: str, last: int) -> tuple[int, int]:
    first = _index(item.get("first"), f"{name}.first", 0, last)
    end = _index(item.get("last"), f"{name}.last", 0, last)
    if end < first:
        raise ValueError(f"{name}.last must not be before its first")
    return first, end


def prepare(request: dict) -> dict:
    """Validate an apply_marks request. Raises ValueError."""
    for key in ("audio", "out"):
        if not isinstance(request.get(key), str) or not request[key]:
            raise ValueError(f"{key} (a file path) is required")
    times = request.get("word_times")
    if not isinstance(times, list) or not times or not all(
            isinstance(pair, list) and len(pair) == 2 and all(_seconds(value) for value in pair) for pair in times):
        raise ValueError("word_times must be a non-empty list of [start, end] pairs in seconds")
    flat = [float(value) for pair in times for value in pair]
    if any(later < earlier for earlier, later in zip(flat, flat[1:])):
        raise ValueError("word_times must not go backwards")
    marks = request.get("marks")
    marks = {} if marks is None else marks
    if not isinstance(marks, dict):
        raise ValueError("marks must be an object")
    for kind in marks:
        if kind not in KINDS:
            raise ValueError(f"Unknown mark: {kind}")
    last = len(times) - 1
    # Silence to insert at each cut, by cut number: cut k is before token k, so a pause after token i is cut i + 1.
    pauses: dict[int, float] = {}
    for n, item in enumerate(_items(marks, "pauses")):
        cut = _index(item.get("after"), f"pauses[{n}].after", -1, last) + 1
        pauses[cut] = pauses.get(cut, 0.0) + _number(item.get("seconds"), f"pauses[{n}].seconds", 0.05, 10)
    speeds = sorted(_span(item, f"speeds[{n}]", last) + (_number(item.get("rate"), f"speeds[{n}].rate", 0.5, 2),)
                    for n, item in enumerate(_items(marks, "speeds")))
    if any(later[0] <= earlier[1] for earlier, later in zip(speeds, speeds[1:])):
        raise ValueError("Speed marks must not overlap")
    return {
        "audio": request["audio"],
        "out": Path(request["out"]).expanduser(),
        "times": [(float(start), float(end)) for start, end in times],
        "pauses": dict(sorted(pauses.items())),
        "speeds": speeds,
        "stresses": [_span(item, f"stresses[{n}]", last) for n, item in enumerate(_items(marks, "stresses"))],
    }


def read(src: str) -> tuple[np.ndarray, int]:
    """Mono samples at the file's own rate. A file soundfile cannot read is decoded at 24 kHz."""
    path = audio._readable(src)
    try:
        samples, rate = sf.read(path, dtype="float32", always_2d=True)
        return samples.mean(axis=1), rate
    except sf.SoundFileError:
        return audio.read_mono(path, edit.RATE), edit.RATE


def quiet_point(samples: np.ndarray, rate: int) -> int:
    """The middle of the quietest stretch: the quietest 20 ms frame (as audio.quietest, unsmoothed) and the frames
    either side of it within QUIET_DB, so a cut in a pause lands in its middle rather than at one edge."""
    frame = round(CUT_FRAME_S * rate)
    count = len(samples) // frame
    if count < 2:
        return len(samples) // 2
    energy = np.mean(samples[:count * frame].reshape(count, frame) ** 2, axis=1)
    first = last = int(np.argmin(energy))
    # Digital silence has no level to compare with, so anything under -100 dBFS counts as quiet too.
    quiet = energy <= max(energy[first] * 10 ** (QUIET_DB / 10), 1e-10)
    while first > 0 and quiet[first - 1]:
        first -= 1
    while last < count - 1 and quiet[last + 1]:
        last += 1
    return (first + last + 1) * frame // 2


def cuts(samples: np.ndarray, rate: int, times: list) -> list[int]:
    """The n + 1 cut points, in samples: the start of the audio, one between each pair of neighbouring tokens, and
    the end. Each inner one is in the quietest 20 ms from REACH_S inside the word before to REACH_S inside the next."""
    points = [0]
    for (_, end), (start, _) in zip(times, times[1:]):
        low = min(len(samples), max(0, round((end - REACH_S) * rate)))
        high = min(len(samples), max(low, round((start + REACH_S) * rate)))
        points.append(min(len(samples), max(points[-1], low + quiet_point(samples[low:high], rate))))
    return points + [len(samples)]


def _voice(samples: np.ndarray, rate: int, tempo: float = 1.0, pitch: float = 0.0) -> np.ndarray:
    """edit_clip's tempo and pitch path: one ffmpeg pass, cut to exactly len / tempo samples."""
    job = {"denoise": False, "warmth": 0, "brightness": 0, "tempo": tempo, "pitch": pitch}
    padded = np.concatenate([np.zeros(round(ATEMPO_LEAD_S * rate), np.float32), samples,
                             np.zeros(round(edit.TAIL_S * rate), np.float32)])
    out = edit.apply(padded, edit.filters(job, samples, rate), rate)[:round(len(samples) / tempo)]
    return np.pad(out, (0, round(len(samples) / tempo) - len(out)))


def stress(samples: np.ndarray, rate: int, spans: list[tuple[int, int]]) -> np.ndarray:
    """Each (start, end) span of samples a little louder and higher: STRESS_DB with raised-cosine ramps inside its
    ends, and the pitch STRESS_SEMITONES up, crossfaded in and out around its ends. One ffmpeg pass for all spans."""
    lifted = _voice(samples, rate, pitch=STRESS_SEMITONES)
    count, half = len(samples), round(CROSSFADE_S * rate / 2)
    mix = np.zeros(count, np.float32)     # 0 the original, 1 the higher copy
    gain = np.zeros(count, np.float32)    # 0 none, 1 all of STRESS_DB
    for start, end in spans:
        if end <= start:
            continue
        low, high = max(0, start - half), min(count, end + half)
        middle = np.arange(low, high) + 0.5
        rise = 1.0 if start == 0 else (middle - start + half) / (2 * half)
        fall = 1.0 if end == count else (end + half - middle) / (2 * half)
        mix[low:high] = np.maximum(mix[low:high], np.clip(np.minimum(rise, fall), 0, 1))
        ramp = max(1, min(round(STRESS_RAMP_S * rate), (end - start) // 2))
        middle = np.arange(start, end) + 0.5
        edge = np.clip(np.minimum(middle - start, end - middle) / ramp, 0, 1)
        gain[start:end] = np.maximum(gain[start:end], 0.5 - 0.5 * np.cos(np.pi * edge))
    angle = np.pi / 2 * mix
    out = samples * np.cos(angle) + lifted * np.sin(angle)
    return (out * (1 + (10 ** (STRESS_DB / 20) - 1) * gain)).astype(np.float32)


def _join(pieces: list[tuple[np.ndarray, int, int]], half: int) -> np.ndarray:
    """Pieces of (samples, where the piece starts in them, its length) laid end to end, each join an equal-power
    crossfade of up to 2 * half samples centred on it, using the audio each piece has beyond its ends."""
    widths = [min(half, len(data) - start - length, next_start, length, next_length)
              for (data, start, length), (_, next_start, next_length) in zip(pieces, pieces[1:])]
    out = np.zeros(sum(length for _, _, length in pieces), np.float32)
    position = 0
    for n, (data, start, length) in enumerate(pieces):
        left = widths[n - 1] if n else 0
        right = widths[n] if n < len(widths) else 0
        part = np.array(data[start - left:start + length + right], dtype=np.float32)
        if left:
            part[:2 * left] *= np.sin(np.pi / 2 * (np.arange(2 * left) + 0.5) / (2 * left))
        if right:
            part[-2 * right:] *= np.cos(np.pi / 2 * (np.arange(2 * right) + 0.5) / (2 * right))
        out[position - left:position + length + right] += part
        position += length
    return out


def speed(samples: np.ndarray, rate: int, spans: list[tuple[int, int, float]]) -> np.ndarray:
    """Each (start, end, tempo) span of samples played at its tempo, keeping the pitch, exactly
    round((end - start) / tempo) samples long. Spans are in order and do not overlap."""
    count, half = len(samples), round(CROSSFADE_S * rate / 2)
    context = 3 * half    # audio each side of a span, so even at 2x it has enough for its crossfades

    def plain(start, end):
        low = max(0, start - half)
        return samples[low:min(count, end + half)], start - low, end - start

    pieces, position = [], 0
    for start, end, tempo in spans:
        if start > position:
            pieces.append(plain(position, start))
        low, high = max(0, start - context), min(count, end + context)
        first, length = round((start - low) / tempo), round((end - start) / tempo)
        changed = _voice(samples[low:high], rate, tempo=tempo)
        pieces.append((np.pad(changed, (0, max(0, first + length - len(changed)))), first, length))
        position = end
    if position < count:
        pieces.append(plain(position, count))
    return _join([piece for piece in pieces if piece[2]], half)


def _mover(spans: list[tuple[int, int, float]]):
    """Where a sample position lands after the speed changes."""
    def move(position: float) -> float:
        shift = 0.0
        for start, end, tempo in spans:
            if position <= start:
                break
            length = round((end - start) / tempo)
            if position < end:
                return start + shift + (position - start) * length / (end - start)
            shift += length - (end - start)
        return position + shift
    return move


def insert_silences(samples: np.ndarray, rate: int, silences: list[tuple[int, int]]) -> np.ndarray:
    """(position, sample count) silences, in order, with a short fade on each side."""
    out = np.array(samples, dtype=np.float32)
    count = round(PAUSE_FADE_S * rate)
    down = 0.5 + 0.5 * np.cos(np.pi * (np.arange(count) + 0.5) / count)
    for position, _ in silences:
        before = out[max(0, position - count):position]
        before *= down[count - len(before):]
        after = out[position:position + count]
        after *= down[::-1][:len(after)]
    pieces, previous = [], 0
    for position, length in silences:
        pieces += [out[previous:position], np.zeros(length, np.float32)]
        previous = position
    return np.concatenate(pieces + [out[previous:]])


def apply_marks(request: dict, check=lambda: None) -> dict:
    """Write the line with its marks. Stress, then speed, then pauses; numpy except for the ffmpeg tempo and pitch
    passes. `check` raises to cancel."""
    job = prepare(request)
    samples, rate = read(job["audio"])
    if not len(samples):
        raise ValueError("The audio is empty")
    times = job["times"]
    cut = cuts(samples, rate, times)
    if job["stresses"]:
        check()
        samples = stress(samples, rate, [(cut[first], cut[last + 1]) for first, last in job["stresses"]])
    spans = [(cut[first], cut[last + 1], tempo) for first, last, tempo in job["speeds"]
             if tempo != 1 and cut[last + 1] > cut[first]]
    if spans:
        check()
        samples = speed(samples, rate, spans)
    move = _mover(spans)

    # Pauses: cut k's silence goes where cut k landed after the speed changes.
    silences = [(round(move(cut[k])), round(seconds * rate)) for k, seconds in job["pauses"].items()]
    gaps, inserted = [], 0      # where each pause starts and ends in the output
    for position, length in silences:
        gaps.append((position + inserted, position + inserted + length))
        inserted += length
    samples = np.clip(insert_silences(samples, rate, silences), -1, 1)

    # Word times: moved like the audio, then kept on their own side of each pause.
    pairs = []
    for index, pair in enumerate(times):
        shift = sum(length for k, (_, length) in zip(job["pauses"], silences) if k <= index)
        pair = [move(value * rate) + shift for value in pair]
        for k, (start, end) in zip(job["pauses"], gaps):
            pair = [min(value, start) if index < k else max(value, end) for value in pair]
        pairs.append((pair[0] / rate, pair[1] / rate))
    duration = len(samples) / rate
    check()
    edit.write(job["out"], samples, rate)
    return {"path": str(job["out"]), "duration": round(duration, 3), "word_times": align.finish(pairs, duration)}
