"""score passes the voice's pronunciation words to Whisper as its prompt (no models)."""

import types

import numpy as np
import pytest

from vocalcord_engine import audio, stt, worker


def test_hint_prompt():
    assert stt.hint_prompt([]) == stt.PROMPT
    assert stt.hint_prompt([" Kuber ", "", "Avalanche"]) == f"{stt.PROMPT} Kuber, Avalanche."


def test_score_prompts_whisper_with_hints(monkeypatch):
    prompts = []

    def transcribe(model, samples, words=True, offset=0.0, prompt=stt.PROMPT):
        prompts.append(prompt)
        return {"text": "Kuber keeps it honest.", "words": []}

    monkeypatch.setattr(stt, "transcribe_array", transcribe)
    monkeypatch.setattr(audio, "read_mono", lambda *args, **kwargs: np.zeros(16000, dtype=np.float32))
    engine = object.__new__(worker.Engine)  # skips loading MLX
    engine._stt = lambda progress: "whisper"
    engine.scorer = types.SimpleNamespace(similarity=lambda a, b: 0.85, naturalness=lambda samples: 3.5)
    job = types.SimpleNamespace(progress=lambda **_: None)
    request = {"audio": "line.wav", "reference": "take.wav", "text": "Kuber keeps it honest."}

    assert engine.score({**request, "hints": ["Kuber"]}, job)["words"] == 100
    engine.score(request, job)
    assert prompts == [stt.hint_prompt(["Kuber"]), stt.PROMPT]
    with pytest.raises(ValueError, match="hints"):
        engine.score({**request, "hints": "Kuber"}, job)
