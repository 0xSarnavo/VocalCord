import pytest

from vocalcord_engine import scoring


def test_normalize_strips_tags_cues_case_and_punctuation():
    assert scoring.normalize("[confident] Hello, World! (sigh) It's “fine” — really?") == [
        "hello", "world", "it's", "fine", "really"]


@pytest.mark.parametrize("text, words", [
    ("3 options", "three options"),
    ("1,250 people", "one thousand two hundred fifty people"),
    ("2.5 times", "two point five times"),
    ("50% off", "fifty percent off"),
    ("twenty-one", "twenty one"),
    ("R&D", "r and d"),
])
def test_normalize_numbers_and_symbols(text, words):
    assert scoring.normalize(text) == words.split()


def test_pitch_and_longest_pause():
    import numpy as np
    rate = scoring.RATE
    t = np.arange(rate) / rate
    voice = 0.3 * np.sin(2 * np.pi * 110 * t) + 0.1 * np.sin(2 * np.pi * 220 * t)   # a low voice with a harmonic
    assert scoring.pitch(voice) == pytest.approx(110, abs=3)
    assert scoring.pitch(np.zeros(rate)) == 0
    gap = np.zeros(int(1.3 * rate))
    assert scoring.longest_pause(np.concatenate([voice, gap, voice])) == pytest.approx(1.3, abs=0.03)
    # Silence before the first word or after the last isn't a gap.
    assert scoring.longest_pause(np.concatenate([gap, voice, gap])) == 0


def test_wer():
    ref = "the cat sat on the mat".split()
    assert scoring.wer(ref, ref) == 0
    assert scoring.wer(ref, "the cat sat on mat".split()) == pytest.approx(1 / 6)       # deletion
    assert scoring.wer(ref, "the bat sat on the mat now".split()) == pytest.approx(2 / 6)  # sub + insertion
    assert scoring.wer([], []) == 0 and scoring.wer([], ["x"]) == 1


def test_words_right_uses_normalized_text():
    assert scoring.words_right("We have 3 options.", "we have three options") == 100
    assert scoring.words_right("[sad] It failed.", "It failed") == 100
    assert scoring.words_right("one two three four", "one two") == 50
    assert scoring.words_right("one", "a b c d") == 0  # WER above 1 floors at 0


def test_like_you_mapping():
    assert scoring.like_you(scoring.SIM_FLOOR) == 0
    assert scoring.like_you(-0.2) == 0
    assert scoring.like_you(scoring.SIM_CEIL) == 100
    assert scoring.like_you(0.99) == 100
    assert scoring.like_you((scoring.SIM_FLOOR + scoring.SIM_CEIL) / 2) == 50
