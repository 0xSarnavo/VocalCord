"""Render a short line from the private sample reference, transcribe it and score it.

Run alone with: .venv/bin/python -m pytest -m slow
"""

from pathlib import Path

import pytest

from vocalcord_engine import tts, worker

SAMPLES = Path(__file__).resolve().parents[2] / "samples"
REFERENCE = SAMPLES / "reference.wav"
TRANSCRIPT = SAMPLES / "reference.txt"
LINE = "Kuber helps friends save money together."


class Job:
    id = "test"
    progress_events: list = []

    def progress(self, **fields):
        self.progress_events.append(fields)

    def check(self):
        pass


@pytest.mark.slow
@pytest.mark.skipif(not REFERENCE.is_file() or not Path(tts.resolve_model("4bit")).is_dir(),
                    reason="needs the private sample reference and the local Breeze 4-bit model")
def test_render_transcribe_score(tmp_path):
    engine = worker.Engine()
    job = Job()
    voice = {"audio": str(REFERENCE), "text": TRANSCRIPT.read_text().strip(),
             "pronunciations": {"Kuber": "Koo-ber"}}
    rendered = engine.render({
        "model": "4bit", "output": str(tmp_path / "line.wav"),
        "lines": [{"text": LINE, "tone": "confident", "voice": voice, "seed": 7}],
    }, job)
    assert Path(rendered["path"]).is_file() and Path(rendered["timing_path"]).is_file()
    assert rendered["lines"][0]["spoken"].startswith("Koo-ber")
    assert 1.0 < rendered["duration"] < 8.0

    heard = engine.transcribe({"audio": rendered["path"]}, job)
    assert engine.large[0].startswith("whisper:")          # Breeze was unloaded first
    assert heard["words"] and heard["words"][-1]["end"] <= rendered["duration"] + 0.5

    scores = engine.score({"audio": rendered["path"], "reference": str(REFERENCE), "text": LINE}, job)
    print(scores)
    assert scores["words"] >= 80                            # "Kuber" may be heard as "Cooper"
    assert scores["like_you"] >= 50
    assert 1.0 <= scores["human"] <= 5.0
    engine.unload({}, job)
    assert engine.status()["large_model"] is None and engine.status()["small_models"] == []
