"""Script marks (pauses, speed, stress) on a synthetic line: five tone "words" with silent gaps (no models)."""

import subprocess

import numpy as np
import pytest
import soundfile as sf

from vocalcord_engine import audio, marks, scoring, worker

RATE = 24000
WORDS = [(0.1, 0.4), (0.6, 0.9), (1.1, 1.4), (1.6, 1.9), (2.1, 2.4)]    # where the words really are
LENGTH = 2.5
# Word times as Whisper gives them: a few hundredths off either way.
TIMES = [[0.12, 0.44], [0.63, 0.88], [1.08, 1.45], [1.62, 1.93], [2.13, 2.38]]
HALF = round(marks.CROSSFADE_S * RATE / 2)


def voice(seconds, f0=150.0, rate=RATE):
    t = np.arange(round(seconds * rate)) / rate
    return audio.fade(sum(0.3 / k * np.sin(2 * np.pi * f0 * k * t) for k in range(1, 6)), rate)


def line(rate=RATE):
    samples = np.zeros(round(LENGTH * rate), np.float32)
    for start, end in WORDS:
        samples[round(start * rate):round(end * rate)] = voice(end - start, rate=rate)
    return samples


def at(seconds):
    return round(seconds * RATE)


def rms(samples):
    return float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))


@pytest.fixture
def source(tmp_path):
    path = tmp_path / "line.wav"
    sf.write(path, line(), RATE, subtype="FLOAT")
    return str(path)


def run(tmp_path, source, times=TIMES, **kinds):
    result = marks.apply_marks({"audio": source, "out": str(tmp_path / "out" / "marked.wav"), "word_times": times,
                                "marks": kinds})
    info = sf.info(result["path"])
    assert (info.samplerate, info.channels, info.subtype) == (RATE, 1, "FLOAT")
    samples = sf.read(result["path"], dtype="float32")[0]
    assert result["duration"] == round(len(samples) / RATE, 3)
    flat = [value for pair in result["word_times"] for value in pair]
    assert len(result["word_times"]) == len(times) and flat == sorted(flat)
    assert [p.name for p in (tmp_path / "out").iterdir()] == ["marked.wav"]      # no temporary file left
    return result, samples


def shifted(times, seconds, first=0):
    return [pair if n < first else [round(value + seconds, 3) for value in pair] for n, pair in enumerate(times)]


def test_no_marks_copies_the_audio_and_the_times(tmp_path, source, monkeypatch):
    def no_ffmpeg(*args, **kwargs):
        raise AssertionError("ffmpeg ran")

    monkeypatch.setattr(subprocess, "run", no_ffmpeg)
    for kinds in ({}, {"pauses": [], "speeds": [], "stresses": []},
                  {"speeds": [{"first": 0, "last": 4, "rate": 1}]}):
        result, out = run(tmp_path, source, **kinds)
        assert np.array_equal(out, line())
        assert result["word_times"] == TIMES and result["duration"] == LENGTH
    result = marks.apply_marks({"audio": source, "out": str(tmp_path / "plain.wav"), "word_times": TIMES})
    assert result["word_times"] == TIMES


def test_a_pause_lands_in_the_silence_between_words(tmp_path, source):
    result, out = run(tmp_path, source, pauses=[{"after": 1, "seconds": 0.5}])
    original, pause = line(), at(0.5)
    assert len(out) == len(original) + pause
    # Untouched up to the end of word 1 and from the start of word 2; only silence between.
    assert np.array_equal(out[:at(0.9)], original[:at(0.9)])
    assert np.array_equal(out[at(1.1) + pause:], original[at(1.1):])
    assert not out[at(0.9):at(1.1) + pause].any()
    assert result["word_times"] == shifted(TIMES, 0.5, first=2)


def test_pauses_add_up(tmp_path, source):
    result, out = run(tmp_path, source, pauses=[{"after": -1, "seconds": 0.25}, {"after": 2, "seconds": 0.3},
                                                {"after": 2, "seconds": 0.2}, {"after": 4, "seconds": 0.4}])
    original = line()
    assert len(out) == len(original) + at(0.25 + 0.5 + 0.4)
    assert result["duration"] == LENGTH + 1.15
    assert not out[:at(0.25 + 0.1)].any() and not out[-at(0.4 + 0.1):].any()
    assert np.array_equal(out[at(0.25):at(0.25 + 1.4)], original[:at(1.4)])
    assert np.array_equal(out[at(0.75 + 1.6):at(0.75 + 2.5)], original[at(1.6):])
    assert result["word_times"] == shifted(shifted(TIMES, 0.25), 0.5, first=3)


@pytest.mark.parametrize("end, start", [(1.06, 1.06), (0.86, 0.86)])
def test_a_pause_keeps_each_word_on_its_side(tmp_path, source, end, start):
    # Word 1's time runs past the cut, or word 2's starts before it: each stops or starts at the pause.
    times = [[0.12, 0.44], [0.63, end], [start, 1.45], [1.62, 1.93], [2.13, 2.38]]
    result, _ = run(tmp_path, source, times=times, pauses=[{"after": 1, "seconds": 0.5}])
    cut = marks.cuts(line(), RATE, [tuple(pair) for pair in times])[2] / RATE
    assert 0.9 <= cut <= 1.1 and (end > cut or start < cut)
    assert result["word_times"][1] == [0.63, round(min(end, cut), 3)]
    assert result["word_times"][2] == [round(max(start, cut) + 0.5, 3), 1.95]


def test_a_cut_goes_in_the_middle_of_the_pause():
    cut = marks.cuts(line(), RATE, [tuple(pair) for pair in TIMES])
    assert [round(point / RATE, 2) for point in cut] == [0, 0.5, 1.0, 1.5, 2.0, LENGTH]
    noisy = line() + 0.001 * np.random.default_rng(0).standard_normal(at(LENGTH)).astype(np.float32)
    assert marks.cuts(noisy, RATE, [tuple(pair) for pair in TIMES])[1:-1] == pytest.approx(cut[1:-1], abs=at(0.03))


@pytest.mark.parametrize("rate", [0.5, 0.8, 1.25, 2.0])
def test_a_speed_span_plays_at_its_rate(tmp_path, source, rate):
    result, out = run(tmp_path, source, speeds=[{"first": 1, "last": 2, "rate": rate}])
    original = line()
    cut = marks.cuts(original, RATE, [tuple(pair) for pair in TIMES])
    span, new_span = cut[3] - cut[1], round((cut[3] - cut[1]) / rate)
    assert len(out) == len(original) - span + new_span
    # Outside the span and its crossfades nothing changes.
    assert np.array_equal(out[:cut[1] - HALF], original[:cut[1] - HALF])
    assert np.array_equal(out[cut[1] + new_span + HALF:], original[cut[3] + HALF:])
    # Times: before the span the same, inside scaled, after it moved by the change in length.
    times = result["word_times"]
    assert times[0] == TIMES[0]
    for n in (1, 2):
        expected = [(cut[1] + (value * RATE - cut[1]) / rate) / RATE for value in TIMES[n]]
        assert times[n] == pytest.approx(expected, abs=0.0011)
    assert times[3:] == shifted(TIMES, (new_span - span) / RATE)[3:]
    # Word 1 sounds for 0.3 / rate s, at its old pitch.
    first, stop = round(times[1][0] * RATE) - at(0.05), round(times[1][1] * RATE) + at(0.05)
    word = out[first:stop]
    frames = word[:len(word) // 240 * 240].reshape(-1, 240)
    assert np.count_nonzero(np.sqrt(np.mean(frames ** 2, axis=1)) > 0.02) / 100 == pytest.approx(0.3 / rate, abs=0.03)
    assert scoring.pitch(word, RATE) == pytest.approx(150, rel=0.02)


def test_spans_side_by_side_and_at_the_edges(tmp_path, source):
    result, out = run(tmp_path, source, speeds=[{"first": 0, "last": 1, "rate": 2.0},
                                                {"first": 2, "last": 4, "rate": 0.5}])
    cut = marks.cuts(line(), RATE, [tuple(pair) for pair in TIMES])
    assert len(out) == round(cut[2] / 2.0) + round((cut[5] - cut[2]) / 0.5)
    last_end = (round(cut[2] / 2.0) + (2.38 * RATE - cut[2]) / 0.5) / RATE
    assert result["word_times"][-1][1] == pytest.approx(last_end, abs=0.0011)


def test_stress_lifts_a_word_and_keeps_the_length(tmp_path, source):
    result, out = run(tmp_path, source, stresses=[{"first": 2, "last": 2}])
    original = line()
    cut = marks.cuts(original, RATE, [tuple(pair) for pair in TIMES])
    assert len(out) == len(original) and result["word_times"] == TIMES
    assert np.array_equal(out[:cut[2] - HALF], original[:cut[2] - HALF])
    assert np.array_equal(out[cut[3] + HALF:], original[cut[3] + HALF:])
    middle = slice(at(1.15), at(1.35))
    assert rms(out[middle]) / rms(original[middle]) == pytest.approx(10 ** (marks.STRESS_DB / 20), rel=0.03)
    assert scoring.pitch(out[middle], RATE) == pytest.approx(150 * 2 ** (marks.STRESS_SEMITONES / 12), abs=0.6)
    assert scoring.pitch(original[middle], RATE) == 150


def test_stress_inside_a_speed_span(tmp_path, source):
    result, out = run(tmp_path, source, speeds=[{"first": 1, "last": 3, "rate": 1.25}],
                      stresses=[{"first": 2, "last": 2}])
    cut = marks.cuts(line(), RATE, [tuple(pair) for pair in TIMES])
    assert len(out) == len(line()) - (cut[4] - cut[1]) + round((cut[4] - cut[1]) / 1.25)
    start, end = (round(value * RATE) for value in result["word_times"][2])
    word = out[start + at(0.04):end - at(0.04)]
    assert scoring.pitch(word, RATE) == pytest.approx(150 * 2 ** (marks.STRESS_SEMITONES / 12), abs=0.6)


def test_other_rates_keep_their_rate(tmp_path):
    path = tmp_path / "48k.wav"
    sf.write(path, line(48000), 48000, subtype="PCM_16")
    result = marks.apply_marks({"audio": str(path), "out": str(tmp_path / "out.wav"), "word_times": TIMES,
                                "marks": {"pauses": [{"after": 0, "seconds": 0.5}],
                                          "stresses": [{"first": 1, "last": 1}]}})
    assert sf.info(result["path"]).samplerate == 48000
    assert result["duration"] == LENGTH + 0.5
    assert result["word_times"] == shifted(TIMES, 0.5, first=1)


def test_cancel_writes_nothing(tmp_path, source):
    def cancel():
        raise worker.Cancelled()

    with pytest.raises(worker.Cancelled):
        marks.apply_marks({"audio": source, "out": str(tmp_path / "out.wav"), "word_times": TIMES,
                           "marks": {"pauses": [{"after": 0, "seconds": 0.5}]}}, cancel)
    assert not (tmp_path / "out.wav").exists()


@pytest.mark.parametrize("change, message", [
    ({"audio": None}, "audio"),
    ({"out": ""}, "out"),
    ({"word_times": []}, "word_times must be a non-empty list"),
    ({"word_times": [[0.1]]}, "word_times"),
    ({"word_times": [[-1, 0.2]]}, "word_times"),
    ({"word_times": [[0.1, "0.2"]]}, "word_times"),
    ({"word_times": [[0.5, 0.4]]}, "word_times must not go backwards"),
    ({"word_times": [[0.1, 0.5], [0.4, 0.6]]}, "word_times must not go backwards"),
    ({"marks": "pause"}, "marks must be an object"),
    ({"marks": {"pause": []}}, "Unknown mark: pause"),
    ({"marks": {"pauses": {"after": 1}}}, r"marks\.pauses must be a list of objects"),
    ({"marks": {"pauses": [{"after": 5, "seconds": 1}]}}, r"pauses\[0\]\.after must be a token index from -1 to 4"),
    ({"marks": {"pauses": [{"after": -2, "seconds": 1}]}}, r"pauses\[0\]\.after"),
    ({"marks": {"pauses": [{"after": True, "seconds": 1}]}}, r"pauses\[0\]\.after"),
    ({"marks": {"pauses": [{"after": 1.0, "seconds": 1}]}}, r"pauses\[0\]\.after"),
    ({"marks": {"pauses": [{"after": 1, "seconds": 0.01}]}}, r"pauses\[0\]\.seconds must be a number from 0.05 to 10"),
    ({"marks": {"pauses": [{"after": 1}]}}, r"pauses\[0\]\.seconds"),
    ({"marks": {"speeds": [{"first": 3, "last": 1, "rate": 1.2}]}}, r"speeds\[0\]\.last must not be before"),
    ({"marks": {"speeds": [{"first": 0, "last": 1, "rate": 3}]}}, r"speeds\[0\]\.rate must be a number from 0.5 to 2"),
    ({"marks": {"speeds": [{"first": 0, "last": 2, "rate": 0.8}, {"first": 2, "last": 3, "rate": 1.2}]}},
     "Speed marks must not overlap"),
    ({"marks": {"stresses": [{"first": 0}]}}, r"stresses\[0\]\.last must be a token index from 0 to 4"),
    ({"marks": {"stresses": [{"first": 0, "last": 5}]}}, r"stresses\[0\]\.last"),
])
def test_bad_requests(change, message):
    with pytest.raises(ValueError, match=message):
        marks.prepare({"audio": "/a.wav", "out": "/b.wav", "word_times": TIMES, **change})


def test_an_unreadable_source_is_an_error(tmp_path):
    with pytest.raises(ValueError, match="File not found"):
        marks.apply_marks({"audio": str(tmp_path / "missing.wav"), "out": str(tmp_path / "out.wav"),
                           "word_times": TIMES})


def test_the_worker_runs_it_as_a_side_command(tmp_path, source):
    assert "apply_marks" in worker.SIDE_COMMANDS and "apply_marks" not in worker.JOB_COMMANDS
    job = worker.Job("m", lambda message: None, lambda job_id: False)
    request = {"audio": source, "out": str(tmp_path / "out.wav"), "word_times": TIMES,
               "marks": {"pauses": [{"after": 4, "seconds": 0.5}]}}
    assert worker.Engine.apply_marks(None, request, job) == {"path": str(tmp_path / "out.wav"), "duration": 3.0,
                                                            "word_times": TIMES}
