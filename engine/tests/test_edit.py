"""Timeline clip edits on synthetic audio (no models)."""

import subprocess

import numpy as np
import pytest
from scipy import signal
import soundfile as sf

from vocalcord_engine import audio, edit, scoring, worker

RATE = edit.RATE


def write(tmp_path, name, samples, rate=RATE):
    path = tmp_path / name
    sf.write(path, np.asarray(samples, dtype=np.float32), rate, subtype="FLOAT")
    return str(path)


def voice(seconds, f0=150.0):
    """A buzzy harmonic tone in bursts: enough like speech for the pitch tracker and the level meter."""
    t = np.arange(round(seconds * RATE)) / RATE
    return sum(0.3 / k * np.sin(2 * np.pi * f0 * k * t) for k in range(1, 6)) * (np.sin(2 * np.pi * 1.5 * t) > 0)


def run(tmp_path, source, **options):
    result = edit.edit_clip({"audio": source, "out": str(tmp_path / "edits" / "clip.wav"), **options})
    info = sf.info(result["path"])
    assert (info.samplerate, info.channels, info.subtype) == (RATE, 1, "FLOAT")
    samples = sf.read(result["path"], dtype="float32")[0]
    assert result["duration"] == round(len(samples) / RATE, 3)
    return result, samples


def rms(samples):
    return float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))


def test_trim_takes_exactly_the_span(tmp_path):
    ramp = np.linspace(-0.5, 0.5, 3 * RATE)
    result, out = run(tmp_path, write(tmp_path, "ramp.wav", ramp), start=0.5, end=2.0)
    assert result == {"path": str(tmp_path / "edits" / "clip.wav"), "duration": 1.5}
    assert np.array_equal(out, ramp[RATE // 2:2 * RATE].astype(np.float32))
    assert [p.name for p in (tmp_path / "edits").iterdir()] == ["clip.wav"]     # no temporary file left


def test_end_past_the_file_or_null_runs_to_its_end(tmp_path):
    source = write(tmp_path, "tone.wav", voice(3.0))
    assert run(tmp_path, source, start=1.0, end=10.0)[0]["duration"] == 2.0
    assert run(tmp_path, source, start=2.5, end=None)[0]["duration"] == 0.5
    assert run(tmp_path, source)[0]["duration"] == 3.0


def test_other_rates_are_resampled(tmp_path):
    source = write(tmp_path, "48k.wav", np.zeros(2 * 48000), rate=48000)
    assert run(tmp_path, source, end=1.5)[0]["duration"] == 1.5


def test_an_empty_span_is_an_error(tmp_path):
    source = write(tmp_path, "tone.wav", voice(3.0))
    with pytest.raises(ValueError, match="Nothing left after trimming: the audio is 3.000 s long"):
        edit.edit_clip({"audio": source, "out": str(tmp_path / "x.wav"), "start": 3.0, "end": 4.0})
    with pytest.raises(ValueError, match="File not found"):
        edit.edit_clip({"audio": str(tmp_path / "missing.wav"), "out": str(tmp_path / "x.wav")})


def test_gain_and_fades(tmp_path):
    source = write(tmp_path, "flat.wav", np.full(RATE, 0.25))
    _, out = run(tmp_path, source, gain_db=6, fade_in=0.2, fade_out=0.3)
    fade_in, fade_out = round(0.2 * RATE), round(0.3 * RATE)
    assert out[0] == 0 and out[-1] == 0
    assert np.all(np.diff(out[:fade_in]) > 0) and np.all(np.diff(out[-fade_out:]) < 0)
    assert np.allclose(out[fade_in:-fade_out], 0.25 * 10 ** (6 / 20))
    # Clipped to full scale; fades longer than the clip are shortened to share it.
    _, loud = run(tmp_path, write(tmp_path, "half.wav", np.full(RATE, 0.5)), gain_db=12, fade_in=10, fade_out=10)
    assert loud.max() == 1.0 and loud[0] == 0 and loud[-1] == 0
    assert np.all(np.diff(loud[:RATE // 2]) >= 0) and np.all(np.diff(loud[RATE // 2:]) <= 0)


def test_plain_edits_run_no_ffmpeg(tmp_path, monkeypatch):
    source = write(tmp_path, "tone.wav", voice(2.0))

    def no_ffmpeg(*args, **kwargs):
        raise AssertionError("ffmpeg ran")

    monkeypatch.setattr(subprocess, "run", no_ffmpeg)
    monkeypatch.setattr(subprocess, "Popen", no_ffmpeg)
    result, _ = run(tmp_path, source, start=0.25, end=1.0, tempo=1, pitch=0, warmth=0, brightness=0, denoise=False,
                    gain_db=-6, fade_in=0.1, fade_out=0.1)
    assert result["duration"] == 0.75


def test_tempo_two_halves_the_duration_and_keeps_the_pitch(tmp_path):
    result, out = run(tmp_path, write(tmp_path, "tone.wav", voice(3.0)), tempo=2.0)
    assert result["duration"] == 1.5
    assert scoring.pitch(out, RATE) == pytest.approx(150, rel=0.02)


@pytest.mark.parametrize("semitones", [5, -12])
def test_pitch_moves_the_voice_and_keeps_the_duration(tmp_path, semitones):
    result, out = run(tmp_path, write(tmp_path, "tone.wav", voice(2.0)), pitch=semitones)
    assert result["duration"] == 2.0
    assert rms(out[-RATE // 10:]) == pytest.approx(rms(voice(2.0)[-RATE // 10:]), rel=0.2)   # the end is not lost
    assert scoring.pitch(out, RATE) == pytest.approx(150 * 2 ** (semitones / 12), rel=0.02)


def test_fades_are_measured_after_the_speed_change(tmp_path):
    t = np.arange(4 * RATE) / RATE
    _, out = run(tmp_path, write(tmp_path, "sine.wav", 0.5 * np.sin(2 * np.pi * 220 * t)), tempo=2.0, fade_in=1.0)
    # Halfway through a 1 s raised-cosine fade the level is half; had the fade been timed on the input, it
    # would be over by 0.5 s of output.
    middle = rms(out[round(0.45 * RATE):round(0.55 * RATE)]) / rms(out[round(1.2 * RATE):round(1.8 * RATE)])
    assert middle == pytest.approx(0.5, abs=0.08)


def test_warmth_and_brightness_move_their_own_band(tmp_path):
    t = np.arange(RATE) / RATE
    source = write(tmp_path, "two.wav", 0.1 * np.sin(2 * np.pi * 50 * t) + 0.1 * np.sin(2 * np.pi * 10000 * t))

    def levels(samples):            # dB at 50 Hz and 10 kHz; 1 s of audio puts each tone on its own FFT bin
        spectrum = np.abs(np.fft.rfft(samples, RATE))
        return 20 * np.log10(spectrum[50] / (0.05 * RATE)), 20 * np.log10(spectrum[10000] / (0.05 * RATE))

    low, high = levels(run(tmp_path, source, warmth=12)[1])
    assert low > 9 and abs(high) < 1
    low, high = levels(run(tmp_path, source, brightness=-12)[1])
    assert abs(low) < 1 and high < -9


def test_denoise_lowers_the_noise_floor_and_keeps_the_timing(tmp_path):
    clean = voice(3.0)
    noisy = clean + 0.02 * np.random.default_rng(0).standard_normal(len(clean))

    def floor(samples):
        meter = audio.LevelMeter(RATE)
        meter.add(samples.astype(np.float32))
        return meter.result()["noise_floor_dbfs"]

    _, out = run(tmp_path, write(tmp_path, "noisy.wav", noisy), denoise=True)
    assert floor(out) < floor(noisy) - 6
    # afftdn's delay is taken back out: same length, and the bursts (the last runs to the end) line up.
    assert len(out) == len(clean)
    lags = signal.correlation_lags(len(out), len(clean))
    assert lags[np.argmax(signal.correlate(out, clean))] == 0


def test_all_tools_at_once(tmp_path):
    result, out = run(tmp_path, write(tmp_path, "tone.wav", voice(3.0)), start=0.5, end=2.5, tempo=0.5, pitch=12,
                      warmth=3, brightness=-3, denoise=True, gain_db=-3, fade_in=0.2, fade_out=0.2)
    assert result["duration"] == 4.0                # (2.5 - 0.5) / 0.5, to the sample
    assert np.abs(out).max() <= 1


@pytest.mark.parametrize("change, message", [
    ({"audio": None}, "audio"),
    ({"out": ""}, "out"),
    ({"start": -1}, "start"),
    ({"start": "0"}, "start"),
    ({"start": 2, "end": 2}, "end must be after start"),
    ({"end": float("inf")}, "end"),
    ({"tempo": 3}, "tempo must be a number from 0.5 to 2"),
    ({"tempo": True}, "tempo"),
    ({"pitch": 13}, "pitch must be a number from -12 to 12"),
    ({"warmth": -13}, "warmth"),
    ({"brightness": 12.5}, "brightness"),
    ({"denoise": "yes"}, "denoise must be true or false"),
    ({"gain_db": 13}, "gain_db must be a number from -24 to 12"),
    ({"fade_in": 11}, "fade_in"),
    ({"fade_out": -1}, "fade_out"),
])
def test_bad_requests(change, message):
    with pytest.raises(ValueError, match=message):
        edit.prepare({"audio": "/a.wav", "out": "/b.wav", **change})


def test_the_worker_runs_it_as_a_side_command(tmp_path):
    assert "edit_clip" in worker.SIDE_COMMANDS and "edit_clip" not in worker.JOB_COMMANDS
    job = worker.Job("e", lambda message: None, lambda job_id: False)
    request = {"audio": write(tmp_path, "tone.wav", voice(1.0)), "out": str(tmp_path / "out.wav"), "end": 0.5}
    assert worker.Engine.edit_clip(None, request, job) == {"path": str(tmp_path / "out.wav"), "duration": 0.5}
