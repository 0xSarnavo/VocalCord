"""Word times for a script line: Whisper's word timestamps lined up with the script's words, so the app can light
up each word as it plays and place script marks between words."""

import difflib
import math

import numpy as np

from . import audio, scoring

# Whisper's word times step by 20 ms, so neighbours this close count as touching.
TOUCH_S = 0.02
# Whisper's boundaries between touching words are often 0.1-0.2 s off; each moves to the quietest point this far
# either side.
SNAP_S = 0.12
SNAP_FRAME_S = 0.01


def parse_tokens(value) -> list[str]:
    """The script's spoken words in order, as the app splits them on whitespace. Raises ValueError."""
    if not isinstance(value, list) or not all(isinstance(token, str) for token in value):
        raise ValueError("tokens must be a list of words")
    return value


def align(tokens: list[str], heard: list[dict], samples: np.ndarray, rate: int) -> dict:
    """One [start, end] per token, in seconds of `samples`, from Whisper's words ({"word", "start", "end"}).
    `matched` is the share of tokens with spoken words that lined up with a word Whisper heard."""
    duration = len(samples) / rate
    words = [scoring.normalize(token) for token in tokens]
    times, matched = match(words, heard, duration)
    spoken = [i for i, token_words in enumerate(words) if token_words]
    snap(times, spoken, samples, rate)
    place_silent(times, words)
    return {"word_times": finish(times, duration), "matched": matched}


def heard_words(heard: list[dict]) -> list[tuple[str, float, float]]:
    """Whisper's words normalised like the script. A word that becomes several ("150") shares its time evenly."""
    found = []
    for word in heard:
        parts = scoring.normalize(str(word.get("word", "")))
        start = float(word["start"])
        step = max(0.0, float(word["end"]) - start) / max(1, len(parts))
        found += [(part, start + k * step, start + (k + 1) * step) for k, part in enumerate(parts)]
    return found


def match(words: list[list[str]], heard: list[dict], duration: float) -> tuple[list, float]:
    """(start, end) for each token with spoken words, None for the rest, and the matched share.

    The script's words and Whisper's are matched with difflib; a token runs from its first matched word's start to
    its last's end. Script words with no match (misheard, respelled) share the gap between their matched neighbours
    by character count."""
    script = [(i, word) for i, token_words in enumerate(words) for word in token_words]
    spoken = heard_words(heard)
    # Each script word's time, None until known.
    word_times: list = [None] * len(script)
    blocks = difflib.SequenceMatcher(None, [word for _, word in script], [word for word, _, _ in spoken],
                                     autojunk=False).get_matching_blocks()
    for a, b, size in blocks:
        for k in range(size):
            word_times[a + k] = spoken[b + k][1:]
    hit = {script[k][0] for k, time in enumerate(word_times) if time is not None}

    # Before the first match: from Whisper's first word. After the last: to its last. Heard nothing: the whole audio.
    first, last = (spoken[0][1], spoken[-1][2]) if spoken else (0.0, duration)
    k = 0
    while k < len(script):
        if word_times[k] is not None:
            k += 1
            continue
        end = k
        while end < len(script) and word_times[end] is None:
            end += 1
        left = word_times[k - 1][1] if k else first
        right = max(left, word_times[end][0] if end < len(script) else last)
        sizes = [len(word) for _, word in script[k:end]]
        position = left
        for index, size in zip(range(k, end), sizes):
            step = (right - left) * size / sum(sizes)
            word_times[index] = (position, position + step)
            position += step
        k = end

    times: list = [None] * len(words)
    for (i, _), (start, end) in zip(script, word_times):
        times[i] = (start, end) if times[i] is None else (min(times[i][0], start), max(times[i][1], end))
    with_words = sum(1 for token_words in words if token_words)
    return times, round(len(hit) / with_words, 3) if with_words else 0.0


def snap(times: list, spoken: list[int], samples: np.ndarray, rate: int) -> None:
    """In place: make the spoken tokens' times run forward, then move each boundary between touching tokens to the
    quietest 10 ms (averaged over 50 ms, so not a dip inside a word) within SNAP_S of it."""
    duration = len(samples) / rate
    position = 0.0
    for i in spoken:
        start = min(duration, max(position, times[i][0]))
        position = min(duration, max(start, times[i][1]))
        times[i] = (start, position)
    for p, q in zip(spoken, spoken[1:]):
        end, start = times[p][1], times[q][0]
        if start - end > TOUCH_S:
            continue
        center = (end + start) / 2
        low, high = max(center - SNAP_S, times[p][0]), min(center + SNAP_S, times[q][1])
        first, stop = round(low * rate), round(high * rate)
        if stop - first >= 2 * round(SNAP_FRAME_S * rate):
            point = (first + audio.quietest(samples[first:stop], rate, frame_s=SNAP_FRAME_S)) / rate
        else:
            point = center
        times[p], times[q] = (times[p][0], point), (point, times[q][1])


def place_silent(times: list, words: list[list[str]]) -> None:
    """In place: a token with no spoken words (like "—") gets no length, halfway between its spoken neighbours, so
    a pause after the word before it still finds the gap."""
    spoken = [i for i, token_words in enumerate(words) if token_words]
    for i, token_words in enumerate(words):
        if token_words:
            continue
        before = [times[p][1] for p in spoken if p < i][-1:]
        after = [times[p][0] for p in spoken if p > i][:1]
        point = (before[0] + after[0]) / 2 if before and after else (before or after or [0.0])[0]
        times[i] = (point, point)


def finish(times: list, duration: float) -> list[list[float]]:
    """Clamped to the audio, rounded to milliseconds, never going backwards."""
    limit = math.floor(duration * 1000) / 1000
    result, position = [], 0.0
    for start, end in times:
        start = max(position, round(min(limit, max(0.0, start)), 3))
        position = max(start, round(min(limit, max(0.0, end)), 3))
        result.append([start, position])
    return result
