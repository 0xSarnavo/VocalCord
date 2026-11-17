"""The export mix with tone "renders" (no models)."""

import json
import subprocess

import numpy as np
import pytest
import soundfile as sf

from vocalcord_engine import audio, mix, worker

RATE = mix.RATE


def tone(tmp_path, name, seconds, level):
    t = np.arange(int(seconds * RATE)) / RATE
    path = tmp_path / f"{name}.wav"
    sf.write(path, (level * np.sin(2 * np.pi * 220 * t) * (np.sin(2 * np.pi * 2 * t) > -0.5)).astype(np.float32), RATE)
    return str(path)


def request(tmp_path, **options):
    return {
        "out_dir": str(tmp_path / "out"), "name": "Launch: film", "lufs": -16,
        "lines": [
            {"audio": tone(tmp_path, "a", 2.0, 0.05), "text": "Meet the [confident] next chapter.", "voice": "Me",
             "pause_after": 0.5, "number": 1},
            {"audio": tone(tmp_path, "b", 3.0, 0.4), "text": "Everything is ready. (sigh)", "voice": "Guest",
             "pause_after": 0.75, "number": 3},
        ],
        **options,
    }


def duration(path):
    out = subprocess.run([audio.FFMPEG.replace("ffmpeg", "ffprobe"), "-v", "error", "-show_entries", "format=duration",
                          "-of", "csv=p=0", str(path)], capture_output=True, text=True, check=True).stdout
    return float(out)


def test_m4a_export_with_every_option(tmp_path):
    result = mix.mix(request(tmp_path, format="m4a", per_line=True, per_voice=True, srt=True, timing=True))
    out = tmp_path / "out"
    assert sorted(p.name for p in out.iterdir()) == [
        "Launch- film Guest.m4a", "Launch- film Me.m4a", "Launch- film line 1.m4a", "Launch- film line 3.m4a",
        "Launch- film.json", "Launch- film.m4a", "Launch- film.srt"]
    assert result["path"] == str(out / "Launch- film.m4a") and result["files"][0] == result["path"]
    # The last line's pause is dropped; levels 0.05 and 0.4 both end up near the target.
    assert result["duration"] == pytest.approx(5.5, abs=0.01)
    assert result["lufs"] == pytest.approx(-16, abs=1)
    assert [(line["start"], line["end"]) for line in result["lines"]] == [(0.0, 2.0), (2.5, 5.5)]
    assert duration(out / "Launch- film.m4a") == pytest.approx(5.5, abs=0.1)
    assert duration(out / "Launch- film line 3.m4a") == pytest.approx(3.0, abs=0.1)
    assert duration(out / "Launch- film Me.m4a") == pytest.approx(5.5, abs=0.1)   # stems span the whole mix
    assert (out / "Launch- film.srt").read_text() == (
        "1\n00:00:00,000 --> 00:00:02,000\nMeet the next chapter.\n\n"
        "2\n00:00:02,500 --> 00:00:05,500\nEverything is ready.\n")
    assert json.loads((out / "Launch- film.json").read_text())[1]["number"] == 3


def test_wav_names_never_clash(tmp_path):
    first = mix.mix(request(tmp_path))
    second = mix.mix(request(tmp_path, srt=True))
    (tmp_path / "out" / "Launch- film 3.srt").write_text("taken")
    third = mix.mix(request(tmp_path, srt=True))
    assert [r["files"] for r in (first, second, third)] == [
        [str(tmp_path / "out" / "Launch- film.wav")],
        [str(tmp_path / "out" / "Launch- film 2.wav"), str(tmp_path / "out" / "Launch- film 2.srt")],
        [str(tmp_path / "out" / "Launch- film 4.wav"), str(tmp_path / "out" / "Launch- film 4.srt")],
    ]
    info = sf.info(first["path"])
    assert (info.samplerate, info.channels, info.subtype) == (RATE, 1, "PCM_16")


def test_cancel_leaves_nothing(tmp_path):
    checks = []

    def check():                     # cancels just before the files are moved into place
        checks.append(1)
        if len(checks) == 7:         # 2 lines, the raw mix, 3 files, then the move
            raise worker.Cancelled()

    with pytest.raises(worker.Cancelled):
        mix.mix(request(tmp_path, format="m4a", per_line=True, srt=True), check=check)
    assert list((tmp_path / "out").iterdir()) == []


@pytest.mark.parametrize("change, message", [
    ({"format": "mp3"}, "format"),
    ({"lines": []}, "lines"),
    ({"lufs": -5}, "lufs"),
    ({"name": " "}, "name"),
])
def test_bad_requests(tmp_path, change, message):
    with pytest.raises(ValueError, match=message):
        mix.prepare({**request(tmp_path), **change})
