"""Whisper transcripts with word timestamps, through mlx-audio."""

import re

import numpy as np
import soundfile as sf

from .audio import quietest

MODEL = "mlx-community/whisper-large-v3-turbo-asr-8bit"
RATE = 16000
# Audio goes to Whisper in chunks of at most one 30 s window, cut at the quietest point in
# the last SEARCH_S seconds. Each chunk is decoded on its own with a short punctuated
# prompt: carrying text across windows made Whisper skip repeated sentences, and without
# the prompt some windows came out all lowercase, hiding sentence ends from split.
CHUNK_S = 30.0
SEARCH_S = 6.0
PROMPT = "Hello, and welcome. Let's begin."


def load():
    from mlx_audio.stt import load as load_stt
    return load_stt(MODEL)


def transcribe_array(model, samples: np.ndarray, words: bool = True, offset: float = 0.0) -> dict:
    """Transcribe 16 kHz mono float32 samples. Word times are shifted by `offset`."""
    if len(samples) < RATE // 10:
        return {"text": "", "words": []}
    result = model.generate(
        samples,
        language="en",
        word_timestamps=words,
        condition_on_previous_text=False,
        initial_prompt=PROMPT,
        hallucination_silence_threshold=2.0 if words else None,
        verbose=None,
    )
    text = re.sub(r"\s+", " ", " ".join(s["text"] for s in result.segments or [])).strip()
    found = []
    for segment in result.segments or []:
        for word in segment.get("words") or []:
            if word["word"].strip():
                found.append({
                    "word": word["word"].strip(),
                    "start": round(float(word["start"]) + offset, 3),
                    "end": round(float(word["end"]) + offset, 3),
                })
    return {"text": text, "words": found}


def transcribe_file(model, wav16k, progress=lambda **_: None, check=lambda: None) -> dict:
    """Transcribe a 16 kHz mono WAV of any length, chunk by chunk (memory stays bounded)."""
    texts, words = [], []
    with sf.SoundFile(str(wav16k)) as source:
        if source.samplerate != RATE:
            raise ValueError("transcribe_file needs 16 kHz audio")
        total = source.frames
        position = 0
        while position < total:
            check()
            source.seek(position)
            chunk = source.read(int(CHUNK_S * RATE), dtype="float32")
            if position + len(chunk) < total:
                search = int(SEARCH_S * RATE)
                cut = len(chunk) - search + quietest(chunk[-search:], RATE)
                chunk = chunk[:cut]
            part = transcribe_array(model, chunk, words=True, offset=position / RATE)
            texts.append(part["text"])
            words.extend(part["words"])
            position += len(chunk)
            progress(stage="transcribe", done=round(position / RATE, 1), total=round(total / RATE, 1))
    return {
        "text": " ".join(t for t in texts if t),
        "words": words,
        "duration": round(total / RATE, 3),
    }
