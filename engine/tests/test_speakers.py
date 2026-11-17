"""group_speakers clusters clips by voice (synthetic embeddings, no models)."""

import types

import numpy as np
import pytest

from vocalcord_engine import audio, scoring, worker


def voices(counts, seed=0, spread=0.35):
    """Unit vectors around one random direction per speaker, like WeSpeaker's 256-d embeddings."""
    rng = np.random.default_rng(seed)
    rows, owners = [], []
    for speaker, count in enumerate(counts):
        centre = rng.normal(size=256)
        centre /= np.linalg.norm(centre)
        for _ in range(count):
            row = centre + spread * rng.normal(size=256) / np.sqrt(256)
            rows.append(row / np.linalg.norm(row))
            owners.append(speaker)
    return np.array(rows), owners


def test_two_speakers_largest_first():
    vectors, owners = voices([6, 10])
    groups = scoring.group_speakers(vectors)
    assert [len(g) for g in groups] == [10, 6]
    for group in groups:
        assert len({owners[i] for i in group}) == 1


def test_one_speaker_drops_a_stray_clip():
    vectors, _ = voices([19])
    stray = np.random.default_rng(1).normal(size=256)
    vectors = np.vstack([vectors, stray / np.linalg.norm(stray)])
    assert scoring.group_speakers(vectors) == [list(range(19))]


def test_small_inputs():
    assert scoring.group_speakers([]) == []
    assert scoring.group_speakers(voices([1])[0]) == [[0]]
    # Two different voices with one clip each: both are strays, so the first (largest) is kept.
    assert scoring.group_speakers(voices([1, 1])[0]) == [[0]]


def test_command_embeds_each_clip(monkeypatch):
    vectors, _ = voices([3, 3])
    paths = [f"/clips/clip-{i:03d}.wav" for i in range(6)]
    monkeypatch.setattr(audio, "read_mono", lambda path, rate: paths.index(path))
    engine = object.__new__(worker.Engine)  # skips loading MLX
    engine.scorer = types.SimpleNamespace(embedding=lambda index: vectors[index])
    progress = []
    job = types.SimpleNamespace(check=lambda: None, progress=lambda **fields: progress.append(fields["done"]))

    result = engine.group_speakers({"clips": paths}, job)
    assert sorted(map(sorted, result["groups"])) == [paths[:3], paths[3:]]
    assert progress == [1, 2, 3, 4, 5, 6]
    assert engine.group_speakers({"clips": []}, job) == {"groups": []}
    with pytest.raises(ValueError, match="clips"):
        engine.group_speakers({"clips": "clip.wav"}, job)
