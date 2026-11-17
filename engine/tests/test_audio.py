import subprocess

import numpy as np
import pytest
import soundfile as sf

from vocalcord_engine import audio

RATE = 48000


def write(tmp_path, name, samples):
    path = tmp_path / name
    sf.write(path, samples.astype(np.float32), RATE, subtype="FLOAT")
    return path


def speechlike(seconds=4.0, level=0.3, floor=0.0, seed=0, silent_edges=True):
    """Tone bursts with gaps, plus optional background noise. Silent edges leave a quarter second without bursts at
    each end, like a recording that starts and stops in silence."""
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * RATE)) / RATE
    bursts = (np.sin(2 * np.pi * 1.5 * t) > 0).astype(np.float32)
    if silent_edges:
        bursts[(t < 0.25) | (t > seconds - 0.25)] = 0
    return level * np.sin(2 * np.pi * 220 * t) * bursts + floor * rng.standard_normal(len(t))


def test_fades_start_and_end_on_silence_and_leave_the_middle():
    faded = audio.fade(np.full(RATE, 0.5, dtype=np.float32), RATE)
    assert faded[0] == 0 and faded[-1] == 0
    assert np.all(np.diff(faded[:round(0.01 * RATE)]) >= 0) and np.all(np.diff(faded[-round(0.03 * RATE):]) <= 0)
    assert np.all(faded[round(0.01 * RATE):-round(0.03 * RATE)] == 0.5)
    assert np.all(np.abs(audio.fade(np.ones(5, dtype=np.float32), RATE)) <= 1)  # shorter than the fades


def test_trim_drops_a_stray_last_sound_but_keeps_a_last_word():
    def tone(seconds):
        return 0.3 * np.sin(2 * np.pi * 220 * np.arange(round(seconds * RATE)) / RATE)
    gap = np.zeros(round(0.5 * RATE))
    pop = audio.trim_outer_silence(np.concatenate([tone(1.0), gap, tone(0.05)]), RATE)
    assert abs(len(pop) / RATE - 1.08) < 0.01      # the speech and its padding, no pop
    word = audio.trim_outer_silence(np.concatenate([tone(1.0), gap, tone(0.3)]), RATE)
    assert len(word) == round(1.8 * RATE)          # all of it: the word ends the clip
    assert len(audio.trim_outer_silence(tone(0.05), RATE)) == round(0.05 * RATE)   # a lone short sound stays


def test_clean_recording_has_no_warnings(tmp_path):
    result = audio.check_audio(write(tmp_path, "clean.wav", speechlike()))
    assert result["duration"] == pytest.approx(4.0, abs=0.01)
    assert result["peak_dbfs"] == pytest.approx(-10.5, abs=0.2)
    assert result["noise_floor_dbfs"] < -80
    assert result["clipping_ratio"] == 0
    assert result["warnings"] == []


def test_quiet_clipped_and_noisy(tmp_path):
    quiet = audio.check_audio(write(tmp_path, "quiet.wav", speechlike(level=0.01)))
    clipped = audio.check_audio(write(tmp_path, "clipped.wav", np.clip(speechlike(level=1.6), -1, 1)))
    noisy = audio.check_audio(write(tmp_path, "noisy.wav", speechlike(floor=0.02)))
    assert quiet["warnings"] == ["quiet"]
    assert clipped["warnings"] == ["clipped"] and clipped["clipping_ratio"] > 0.1
    assert noisy["warnings"] == ["noisy"] and noisy["noise_floor_dbfs"] > -50


def test_a_recording_that_starts_or_stops_mid_word_is_cut_off(tmp_path):
    cut = audio.check_audio(write(tmp_path, "cut.wav", speechlike(silent_edges=False)))
    assert cut["warnings"] == ["cut_off"]
    ends = speechlike()
    ends[-RATE // 10:] = 0.3 * np.sin(2 * np.pi * 220 * np.arange(RATE // 10) / RATE)   # still talking at the end
    assert audio.check_audio(write(tmp_path, "ends.wav", ends))["warnings"] == ["cut_off"]


def test_reads_video_files(tmp_path):
    wav = write(tmp_path, "voice.wav", speechlike(seconds=2.0))
    video = tmp_path / "clip.mp4"
    subprocess.run([audio.FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=2",
                    "-i", str(wav), "-shortest", "-c:v", "libx264", "-c:a", "aac", str(video)], check=True)
    assert audio.check_audio(video)["duration"] == pytest.approx(2.0, abs=0.1)
    out = tmp_path / "16k.wav"
    audio.decode(video, {out: 16000})
    info = sf.info(out)
    assert (info.samplerate, info.channels) == (16000, 1)


def test_unreadable_file_is_a_clear_error(tmp_path):
    bad = tmp_path / "notes.txt"
    bad.write_text("not audio")
    with pytest.raises(ValueError, match="Could not read audio"):
        audio.check_audio(bad)
    with pytest.raises(ValueError, match="File not found"):
        audio.check_audio(tmp_path / "missing.wav")


def test_ffmpeg_falls_back_to_the_wheel(monkeypatch):
    monkeypatch.setattr(audio.shutil, "which", lambda name: None)
    monkeypatch.setattr(audio.os, "access", lambda path, mode: False)
    assert "imageio_ffmpeg" in audio.find_ffmpeg()
