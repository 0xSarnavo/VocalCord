"""Cut free speech into reference clips at natural pauses, from word timestamps."""

import numpy as np

from .audio import quietest

MIN_S = 3.0
MAX_S = 20.0
MIN_PAUSE = 0.25        # a gap this long between words counts as a natural pause
MAX_INSIDE_PAUSE = 1.5  # a clip never spans a silence longer than this
PAD = 0.2               # planning estimate of the silence kept around a clip
EDGE_SLACK = (0.2, 0.5)  # refine_edges can shorten a clip by ~0.2 s or lengthen it by ~0.5 s
SENTENCE_END = (".", "?", "!")
KEEP_SILENCE = 0.08     # silence left at each end after trimming


def plan_clips(words: list[dict], duration: float, min_s: float = MIN_S, max_s: float = MAX_S) -> list[dict]:
    """Return clips [{first, last, start, end, text}] (word indices, estimated times) that are
    min_s..max_s long, cut at pauses or sentence ends, preferring sentence ends and longer
    pauses. Words before a long silence that cannot make a min_s clip are dropped."""
    if not 0 < min_s < max_s:
        raise ValueError("Clip lengths must satisfy 0 < min_s < max_s")
    count = len(words)
    gap_after = [words[i + 1]["start"] - words[i]["end"] if i + 1 < count else float("inf") for i in range(count)]

    def bounds(first: int, last: int) -> tuple[float, float]:
        before = words[first]["start"] - words[first - 1]["end"] if first else words[first]["start"]
        start = words[first]["start"] - min(PAD, max(before, 0) / (2 if first else 1))
        end_gap = gap_after[last] if last + 1 < count else duration - words[last]["end"]
        end = words[last]["end"] + min(PAD, max(end_gap, 0) / (2 if last + 1 < count else 1))
        return max(0.0, start), min(duration, end)

    clips = []
    first = 0
    while first < count:
        best, best_score, fallback, fallback_gap = None, None, None, -1.0
        last = first
        while last < count:
            start, end = bounds(first, last)
            if end - start > max_s:
                break
            long_enough = end - start >= min_s
            sentence_end = words[last]["word"].endswith(SENTENCE_END)
            if long_enough and (gap_after[last] >= MIN_PAUSE or sentence_end or last == count - 1):
                score = min(gap_after[last], 1.0) + (0.3 if sentence_end else 0)
                if best_score is None or score >= best_score:
                    best, best_score = last, score
            if long_enough and gap_after[last] >= fallback_gap:
                fallback, fallback_gap = last, gap_after[last]
            if gap_after[last] > MAX_INSIDE_PAUSE:
                break
            last += 1
        chosen = best if best is not None else fallback
        if chosen is None:
            # Too short before a long silence (or one word longer than max_s): drop it.
            first = min(last, count - 1) + 1
            continue
        start, end = bounds(first, chosen)
        clips.append({
            "first": first,
            "last": chosen,
            "start": round(start, 3),
            "end": round(end, 3),
            "text": " ".join(w["word"] for w in words[first:chosen + 1]),
        })
        first = chosen + 1
    return clips


def refine_edges(clip: dict, words: list[dict], read, rate: int, duration: float) -> tuple[float, float]:
    """Move a clip's edges into real silence. Whisper's word times can be ~0.2 s off (a
    word's start often swallows the pause before it), so each edge goes to the quietest
    20 ms between the neighbouring words, then outer silence is trimmed to 80 ms.
    `read(t0, t1)` returns mono samples at `rate` for that span."""
    def mid(word):
        return (word["start"] + word["end"]) / 2

    first, last = words[clip["first"]], words[clip["last"]]
    lo = words[clip["first"] - 1]["end"] - 0.05 if clip["first"] else max(0.0, first["start"] - 0.5)
    lo = min(lo, first["start"])
    start = lo + quietest(read(lo, mid(first)), rate) / rate
    hi = mid(words[clip["last"] + 1]) if clip["last"] + 1 < len(words) else min(duration, last["end"] + 0.5)
    hi = max(hi, last["end"])
    end = last["end"] - 0.05 + quietest(read(last["end"] - 0.05, hi), rate) / rate
    piece = np.abs(read(start, end))
    audible = np.flatnonzero(piece > max(0.002, float(piece.max(initial=0)) * 0.005))
    if len(audible):
        keep = round(KEEP_SILENCE * rate)
        start, end = start + max(0, audible[0] - keep) / rate, start + min(len(piece), audible[-1] + keep + 1) / rate
    return round(start, 3), round(end, 3)
