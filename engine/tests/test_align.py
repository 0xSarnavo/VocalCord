"""Word times: Whisper's words lined up with the script's tokens, and the score and time_words commands that return
them (no models)."""

import types

import numpy as np
import pytest

from vocalcord_engine import align, audio, stt, worker

RATE = 16000


def heard(*words):
    return [{"word": word, "start": start, "end": end} for word, start, end in words]


def speech(seconds, *spans):
    """Noise "words" over the given (start, end) spans, silence elsewhere."""
    samples = np.zeros(round(seconds * RATE), np.float32)
    rng = np.random.default_rng(0)
    for start, end in spans:
        first, stop = round(start * RATE), round(end * RATE)
        samples[first:stop] = 0.2 * rng.standard_normal(stop - first)
    return samples


def times(words, whisper, duration=3.0):
    """Times before snapping, rounded for comparing."""
    found, matched = align.match([align.scoring.normalize(word) for word in words], whisper, duration)
    return [None if pair is None else [round(pair[0], 3), round(pair[1], 3)] for pair in found], matched


def test_exact_match():
    tokens = ["Kuber", "keeps", "every", "circle", "honest."]
    whisper = heard(("Kuber", 0.1, 0.4), ("keeps", 0.5, 0.8), ("every", 0.9, 1.1), ("circle", 1.2, 1.5),
                    ("honest.", 1.6, 2.0))
    result = align.align(tokens, whisper, speech(2.5, (0.1, 0.4), (0.5, 0.8), (0.9, 1.1), (1.2, 1.5), (1.6, 2.0)),
                         RATE)
    assert result == {"word_times": [[0.1, 0.4], [0.5, 0.8], [0.9, 1.1], [1.2, 1.5], [1.6, 2.0]], "matched": 1.0}


def test_numbers_match_however_they_are_written():
    # The script's "150" is three words; Whisper wrote them out, with an "and" the script does not have.
    found, matched = times(["Save", "150", "dollars."],
                           heard(("Save", 0.1, 0.4), ("one", 0.5, 0.6), ("hundred", 0.6, 0.9), ("and", 0.9, 1.0),
                                 ("fifty", 1.0, 1.3), ("dollars.", 1.4, 1.8)))
    assert (found, matched) == ([[0.1, 0.4], [0.5, 1.3], [1.4, 1.8]], 1.0)
    # Whisper wrote digits and the script words: "$150" becomes three words that share its time evenly.
    found, matched = times(["Save", "one", "hundred", "fifty", "dollars."],
                           heard(("Save", 0.1, 0.4), ("$150", 0.5, 1.1), ("dollars.", 1.2, 1.6)))
    assert (found, matched) == ([[0.1, 0.4], [0.5, 0.7], [0.7, 0.9], [0.9, 1.1], [1.2, 1.6]], 1.0)


def test_misheard_words_fill_the_gap_by_length():
    whisper = heard(("Cooper", 0.1, 0.4), ("keeps", 0.5, 0.8), ("every", 0.9, 1.1), ("saving", 1.2, 1.5),
                    ("surface", 1.5, 1.9), ("honest.", 2.0, 2.4))
    found, matched = times(["Kuber", "keeps", "every", "savings", "circle", "honest."], whisper)
    # Before the first match the gap starts at Whisper's first word; "savings circle" share 1.1-2.0 by 7:6 letters.
    assert found == [[0.1, 0.5], [0.5, 0.8], [0.9, 1.1], [1.1, 1.585], [1.585, 2.0], [2.0, 2.4]]
    assert matched == 0.5
    # After the last match the gap ends at Whisper's last word.
    found, _ = times(["Thanks", "Kuber"], heard(("Thanks", 0.1, 0.5), ("Cougar.", 0.6, 1.0)))
    assert found == [[0.1, 0.5], [0.5, 1.0]]


def test_a_respelled_word_takes_the_respelling_time():
    # Rendered from "Koo-ber", heard that way: two words, neither the script's "Kuber".
    found, matched = times(["Kuber", "keeps", "it."],
                           heard(("Koo-ber", 0.1, 0.4), ("keeps", 0.5, 0.8), ("it.", 0.9, 1.0)))
    assert found == [[0.1, 0.5], [0.5, 0.8], [0.9, 1.0]]
    assert matched == round(2 / 3, 3)


def test_nothing_matched_or_nothing_heard():
    # Nothing matches: spread over Whisper's words by letters. "—" has no spoken words and no time yet.
    found, matched = times(["a", "bb", "—"], heard(("x", 0.5, 0.8), ("y", 1.0, 2.0)))
    assert (found, matched) == ([[0.5, 1.0], [1.0, 2.0], None], 0.0)
    # Nothing heard: spread over the whole audio.
    found, matched = times(["a", "bb"], [])
    assert (found, matched) == ([[0.0, 1.0], [1.0, 3.0]], 0.0)
    result = align.align(["a", "bb"], [], speech(3.0, (0.0, 0.97), (1.03, 3.0)), RATE)
    assert result["matched"] == 0.0
    assert result["word_times"][0][1] == pytest.approx(1.0, abs=0.012)


def test_a_token_without_spoken_words_sits_in_the_gap():
    whisper = heard(("Hello", 0.1, 0.5), ("world.", 0.7, 1.0))
    result = align.align(["Hello", "—", "world."], whisper, speech(1.2, (0.1, 0.5), (0.7, 1.0)), RATE)
    assert result == {"word_times": [[0.1, 0.5], [0.6, 0.6], [0.7, 1.0]], "matched": 1.0}
    assert align.align(["—"], [], speech(1.0), RATE)["word_times"] == [[0.0, 0.0]]
    assert align.align([], whisper, speech(1.2), RATE) == {"word_times": [], "matched": 0.0}


def test_touching_boundaries_snap_to_the_silence():
    # Real words at 0.10-0.50 and 0.66-1.00, 0.70-1.00 and 1.00-1.40 (no gap). Whisper puts the first boundary
    # 0.2 s late, inside the second word, and the second at the right place.
    audio_ = speech(1.6, (0.1, 0.5), (0.66, 1.0), (1.0, 1.4))
    audio_[round(0.98 * RATE):round(1.02 * RATE)] = 0         # the small dip between the touching words
    whisper = heard(("One", 0.1, 0.72), ("two", 0.72, 1.0), ("three.", 1.0, 1.4))
    result = align.align(["One", "two", "three."], whisper, audio_, RATE)["word_times"]
    assert 0.5 <= result[0][1] == result[1][0] <= 0.66            # moved back into the silence
    assert result[1][1] == result[2][0] == pytest.approx(1.0, abs=0.012)
    assert result[0][0] == 0.1 and result[2][1] == 1.4
    # A boundary with a gap Whisper heard is left alone.
    whisper = heard(("One", 0.1, 0.45), ("two", 0.7, 1.0))
    assert align.align(["One", "two"], whisper, audio_, RATE)["word_times"] == [[0.1, 0.45], [0.7, 1.0]]


def test_times_are_clamped_rounded_and_never_go_backwards():
    whisper = heard(("one", -0.2, 0.31234), ("two", 0.3, 0.9), ("three", 0.8, 1.7))
    result = align.align(["one", "two", "three"], whisper, speech(1.5), RATE)["word_times"]
    flat = [value for pair in result for value in pair]
    assert flat == sorted(flat) and flat[0] == 0.0 and flat[-1] == 1.5
    assert all(value == round(value, 3) for value in flat)


def test_parse_tokens():
    assert align.parse_tokens(["Hi", "—"]) == ["Hi", "—"]
    for bad in ("Hi there", [1], None):
        with pytest.raises(ValueError, match="tokens must be a list of words"):
            align.parse_tokens(bad)


# --- score and time_words --------------------------------------------------

WHISPER = {"text": "Kuber keeps it.", "words": heard(("Kuber", 0.1, 0.4), ("keeps", 0.5, 0.8), ("it.", 0.9, 1.0))}


@pytest.fixture
def engine(monkeypatch):
    calls = []

    def transcribe(model, samples, words=True, offset=0.0, prompt=stt.PROMPT):
        calls.append({"words": words, "prompt": prompt})
        return WHISPER

    monkeypatch.setattr(stt, "transcribe_array", transcribe)
    monkeypatch.setattr(audio, "read_mono", lambda *args, **kwargs: speech(1.2, (0.1, 0.4), (0.5, 0.8), (0.9, 1.0)))
    engine = object.__new__(worker.Engine)  # skips loading MLX
    engine._stt = lambda progress: "whisper"
    engine.scorer = types.SimpleNamespace(similarity=lambda a, b: 0.85, naturalness=lambda samples: 3.5)
    engine.calls = calls
    return engine


JOB = types.SimpleNamespace(progress=lambda **_: None, check=lambda: None)


def test_score_adds_word_times_only_when_given_tokens(engine):
    request = {"audio": "line.wav", "reference": "take.wav", "text": "Kuber keeps it."}
    plain = engine.score(request, JOB)
    assert "word_times" not in plain and "matched" not in plain
    timed = engine.score({**request, "tokens": ["Kuber", "keeps", "it."], "hints": ["Kuber"]}, JOB)
    assert timed == {**plain, "word_times": [[0.1, 0.4], [0.5, 0.8], [0.9, 1.0]], "matched": 1.0}
    assert engine.calls == [{"words": False, "prompt": stt.PROMPT},
                            {"words": True, "prompt": stt.hint_prompt(["Kuber"])}]
    with pytest.raises(ValueError, match="tokens"):
        engine.score({**request, "tokens": "Kuber keeps it."}, JOB)


def test_time_words(engine):
    result = engine.time_words({"audio": "line.wav", "tokens": ["Kuber", "keeps", "it."]}, JOB)
    assert result == {"word_times": [[0.1, 0.4], [0.5, 0.8], [0.9, 1.0]], "heard": "Kuber keeps it.", "matched": 1.0}
    with pytest.raises(ValueError, match="tokens"):
        engine.time_words({"audio": "line.wav", "tokens": []}, JOB)
    with pytest.raises(ValueError, match="hints"):
        engine.time_words({"audio": "line.wav", "tokens": ["Hi"], "hints": "Kuber"}, JOB)
    with pytest.raises(ValueError, match="audio"):
        engine.time_words({"tokens": ["Hi"]}, JOB)
