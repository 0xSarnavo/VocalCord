from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from vocalcord_engine import tts, worker


def test_tone_key_and_free_instruction():
    assert tts.resolve_tone("Confident") == tts.STYLES["confident"]
    assert tts.resolve_tone(None) == tts.STYLES["neutral"]
    assert tts.resolve_tone("Speak like a sports commentator") == "Speak like a sports commentator"


def test_parse_line_tags():
    items = tts.parse_line("Hello there. [pause 0.30] [breath] [sad] It failed. [Whisper it] Quietly.", "happy")
    assert items == [
        ("speech", "Hello there.", tts.STYLES["happy"]),
        ("pause", 0.3, ""),
        ("breath", 0.0, ""),
        ("speech", "It failed.", tts.STYLES["sad"]),
        ("speech", "Quietly.", "Whisper it"),
    ]


def test_parse_line_keeps_sigh_inside_speech():
    assert tts.parse_line("Well (sigh) fine.") == [("speech", "Well (sigh) fine.", tts.STYLES["neutral"])]


@pytest.mark.parametrize("text, message", [
    ("Wait [pause 11]", "at most 10"),
    ("Wait [pause]", "[pause 0.30]"),
])
def test_parse_line_rejects_bad_pauses(text, message):
    with pytest.raises(ValueError, match=message.replace("[", r"\[").replace("]", r"\]")):
        tts.parse_line(text)


def test_pronunciations_whole_words_only():
    spoken = tts.apply_pronunciations("Kuber, kuber's Kuberverse. KUBER", {"Kuber": "Koo-ber"})
    assert spoken == "Koo-ber, Koo-ber's Kuberverse. Koo-ber"


def _request(tmp_path, **line):
    ref = tmp_path / "ref.wav"
    ref.write_bytes(b"RIFF")
    voice = {"audio": str(ref), "text": "Reference words.", "pronunciations": {"Kuber": "Koo-ber"}}
    return {"output": str(tmp_path / "out.wav"), "model": str(tmp_path),
            "lines": [{"text": "Kuber works. [pause 0.2]", "voice": voice, **line}]}


def test_prepare_applies_pronunciations_to_speech_only(tmp_path):
    job = tts.prepare(_request(tmp_path, tone="soft", pause_after=0.5, seed=3))
    line = job["lines"][0]
    assert line["text"] == "Kuber works. [pause 0.2]"
    assert line["items"] == [("speech", "Koo-ber works.", tts.STYLES["soft"]), ("pause", 0.2, "")]
    assert (line["pause_after"], line["seed"], job["cfg_scale"], job["lufs"]) == (0.5, 3, 4.0, -16.0)


@pytest.mark.parametrize("change, message", [
    ({"pause_after": 12}, "pause_after"),
    ({"seed": "x"}, "seed"),
    ({"text": "[pause 1]"}, "no spoken text"),
    ({"text": "Hi [breath]"}, "voice.breath"),
])
def test_prepare_rejects_bad_lines(tmp_path, change, message):
    with pytest.raises(ValueError, match="Line 1: .*" + message.replace(".", r"\.")):
        tts.prepare(_request(tmp_path, **change))


def test_prepare_rejects_bad_settings(tmp_path):
    request = _request(tmp_path)
    with pytest.raises(ValueError, match="cfg_scale"):
        tts.prepare({**request, "cfg_scale": 9})
    with pytest.raises(ValueError, match="lines"):
        tts.prepare({**request, "lines": []})


class _Model:
    """Stands in for Breeze: a short tone per spoken part."""
    sample_rate = 24000

    def generate(self, **_):
        t = np.arange(4800) / self.sample_rate
        return [SimpleNamespace(audio=0.3 * np.sin(2 * np.pi * 220 * t))]


def test_cancel_during_the_last_line_writes_nothing(tmp_path):
    job = tts.prepare(_request(tmp_path))
    checks = []

    def check():                     # passes before the line, cancels before the write
        checks.append(1)
        if len(checks) > 1:
            raise worker.Cancelled()

    with pytest.raises(worker.Cancelled):
        tts.render(_Model(), job, check=check)
    assert sorted(p.name for p in tmp_path.iterdir()) == ["ref.wav"]

    result = tts.render(_Model(), job)
    assert Path(result["path"]).is_file() and Path(result["timing_path"]).is_file()
    assert sorted(p.name for p in tmp_path.iterdir()) == ["out.json", "out.wav", "ref.wav"]
