import numpy as np
import pytest

from vocalcord_engine.clips import plan_clips, refine_edges


def speech(*phrases, start=0.5, word_s=0.4, pause_s=0.6):
    """Synthetic word timestamps: phrases separated by pause_s (or a (text, pause) tuple)."""
    words, t = [], start
    for phrase in phrases:
        text, pause = phrase if isinstance(phrase, tuple) else (phrase, pause_s)
        for word in text.split():
            words.append({"word": word, "start": round(t, 3), "end": round(t + word_s, 3)})
            t += word_s + 0.05
        t += pause - 0.05
    return words, round(t + 0.5, 3)


def test_clips_respect_length_and_cut_at_pauses():
    words, duration = speech(*["one two three four five six seven eight."] * 8)
    clips = plan_clips(words, duration)
    assert clips
    for clip in clips:
        assert 3 <= clip["end"] - clip["start"] <= 20
        assert clip["text"].endswith("eight.")   # every cut lands on a phrase end
    assert sum(len(c["text"].split()) for c in clips) == len(words)


def test_clip_text_and_padding():
    words, duration = speech("Hello there my friend.", "How are you doing today?", pause_s=0.8)
    clips = plan_clips(words, duration, min_s=1, max_s=20)
    assert [c["text"] for c in clips] == ["Hello there my friend. How are you doing today?"]
    assert clips[0]["start"] == pytest.approx(0.3)          # 0.2 s of lead-in kept
    assert clips[0]["end"] == pytest.approx(words[-1]["end"] + 0.2)


def test_prefers_sentence_end_over_slightly_longer_pause():
    words, duration = speech(("a b c d e f g h.", 0.5), ("i j k l m n o", 0.6), "p q r s t u v w.", pause_s=0.5)
    clips = plan_clips(words, duration, min_s=3, max_s=8)
    assert clips[0]["text"] == "a b c d e f g h."


def test_cuts_at_sentence_end_even_without_a_gap():
    # Whisper often folds a pause into the next word's start, leaving no gap.
    words, duration = speech("a b c d e f g h.", "i j k l m n o p.", pause_s=0.05)
    clips = plan_clips(words, duration, min_s=3, max_s=6)
    assert [c["text"] for c in clips] == ["a b c d e f g h.", "i j k l m n o p."]
    assert [(c["first"], c["last"]) for c in clips] == [(0, 7), (8, 15)]


def test_drops_short_fragment_before_long_silence():
    words, duration = speech(("Yes.", 3.0), "this part is long enough to keep as a clip.")
    clips = plan_clips(words, duration)
    assert [c["text"] for c in clips] == ["this part is long enough to keep as a clip."]


def test_no_pauses_falls_back_to_largest_gap_within_max():
    words, duration = speech(" ".join(f"w{i}" for i in range(80)))   # 36 s with no pauses at all
    clips = plan_clips(words, duration)
    assert len(clips) >= 2
    assert all(3 <= c["end"] - c["start"] <= 20 for c in clips)


def test_empty_and_bad_limits():
    assert plan_clips([], 10.0) == []
    with pytest.raises(ValueError):
        plan_clips([], 10.0, min_s=5, max_s=4)


def test_refine_edges_moves_cuts_into_silence():
    rate = 16000
    samples = np.zeros(5 * rate, dtype=np.float32)
    tone = 0.3 * np.sin(2 * np.pi * 200 * np.arange(rate) / rate)
    for at in (1.0, 2.6):                       # real speech: 1.0-2.0 s and 2.6-3.6 s
        samples[int(at * rate):int(at * rate) + rate] = tone
    # Whisper-like times: the first word ends early, the second word's start swallows the pause.
    words = [{"word": "one.", "start": 0.9, "end": 1.85}, {"word": "two.", "start": 1.85, "end": 3.6}]

    def read(t0, t1):
        return samples[max(0, int(t0 * rate)):max(0, int(t1 * rate))]

    start, end = refine_edges({"first": 0, "last": 0}, words, read, rate, 5.0)
    assert start == pytest.approx(0.92, abs=0.02)   # 80 ms before the speech
    assert 2.0 < end < 2.1                           # whole word kept, cut inside the pause
    start, end = refine_edges({"first": 1, "last": 1}, words, read, rate, 5.0)
    assert start == pytest.approx(2.52, abs=0.02)
    assert 3.6 < end <= 3.7
