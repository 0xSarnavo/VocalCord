"""The three line scores: like_you (speaker similarity), human (UTMOS) and words (1 - WER)."""

import re
import unicodedata

import numpy as np

SPEAKER_MODEL = ("Wespeaker/wespeaker-voxceleb-resnet34-LM", "voxceleb_resnet34_LM.onnx")
MOS_MODEL = ("TigreGotico/utmos-onnx", "utmos22_strong.onnx")
RATE = 16000
MOS_WINDOW_S = 20.0  # UTMOS attention grows with length; long audio is scored in windows

# Raw cosine similarity -> like_you %. Calibrated on this Mac's samples (README):
# other speakers scored -0.13..0.22, Breeze clones of the reference 0.70..0.80,
# another real recording of the same person 0.84.
SIM_FLOOR = 0.25
SIM_CEIL = 0.85


def like_you(similarity: float) -> int:
    return round(100 * min(1.0, max(0.0, (similarity - SIM_FLOOR) / (SIM_CEIL - SIM_FLOOR))))


# --- words ---------------------------------------------------------------

_ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
_TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def number_words(n: int) -> str:
    if n < 20:
        return _ONES[n]
    if n < 100:
        return _TENS[n // 10] + ("" if n % 10 == 0 else " " + _ONES[n % 10])
    for size, name in ((10**9, "billion"), (10**6, "million"), (1000, "thousand"), (100, "hundred")):
        if n >= size:
            rest = n % size
            return f"{number_words(n // size)} {name}" + (f" {number_words(rest)}" if rest else "")
    raise AssertionError


def _spell_number(match: re.Match) -> str:
    whole, _, fraction = match.group(0).replace(",", "").partition(".")
    if len(whole) > 12:
        return " ".join(_ONES[int(d)] for d in whole)
    spoken = number_words(int(whole))
    if fraction:
        spoken += " point " + " ".join(_ONES[int(d)] for d in fraction)
    return f" {spoken} "


def normalize(text: str) -> list[str]:
    """Words for WER: drop [tags] and (cues), lowercase, spell out numbers, strip punctuation."""
    text = unicodedata.normalize("NFKC", text)
    text = re.sub(r"\[[^\]]*\]|\([^)]*\)", " ", text)
    text = text.lower().replace("’", "'").replace("‘", "'")
    text = text.replace("%", " percent ").replace("&", " and ")
    text = re.sub(r"\d[\d,]*(?:\.\d+)?", _spell_number, text)
    text = re.sub(r"[^\w\s']|_", " ", text)            # punctuation and hyphens become spaces
    text = re.sub(r"(?<!\w)'|'(?!\w)", " ", text)      # keep apostrophes only inside words
    return text.split()


def wer(reference: list[str], hypothesis: list[str]) -> float:
    if not reference:
        return 0.0 if not hypothesis else 1.0
    previous = list(range(len(hypothesis) + 1))
    for i, ref_word in enumerate(reference, 1):
        current = [i]
        for j, hyp_word in enumerate(hypothesis, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ref_word != hyp_word)))
        previous = current
    return previous[-1] / len(reference)


def words_right(script: str, heard: str) -> int:
    return round(100 * max(0.0, 1.0 - wer(normalize(script), normalize(heard))))


# --- small ONNX models ---------------------------------------------------

def fbank(samples: np.ndarray) -> np.ndarray:
    """80-bin Kaldi fbank with mean normalisation, as WeSpeaker's infer_onnx.py."""
    import kaldi_native_fbank as knf

    options = knf.FbankOptions()
    options.frame_opts.dither = 0.0
    options.frame_opts.samp_freq = RATE
    options.frame_opts.window_type = "hamming"
    options.mel_opts.num_bins = 80
    computer = knf.OnlineFbank(options)
    computer.accept_waveform(RATE, (samples * 32768).tolist())
    computer.input_finished()
    if computer.num_frames_ready == 0:
        raise ValueError("Audio is too short to score")
    feats = np.stack([computer.get_frame(i) for i in range(computer.num_frames_ready)])
    return (feats - feats.mean(axis=0)).astype(np.float32)


class Scorer:
    """Holds the two small ONNX sessions (about 440 MB together once loaded)."""

    def __init__(self):
        self.speaker = None
        self.mos = None

    @staticmethod
    def _session(repo_file):
        import onnxruntime as ort
        from huggingface_hub import hf_hub_download

        options = ort.SessionOptions()
        options.log_severity_level = 3
        return ort.InferenceSession(hf_hub_download(*repo_file), options, providers=["CPUExecutionProvider"])

    def loaded(self) -> list[str]:
        return [name for name, session in (("speaker", self.speaker), ("utmos", self.mos)) if session]

    def unload(self) -> None:
        self.speaker = self.mos = None

    def embedding(self, samples: np.ndarray) -> np.ndarray:
        if self.speaker is None:
            self.speaker = self._session(SPEAKER_MODEL)
        vector = self.speaker.run(None, {"feats": fbank(samples)[None]})[0][0]
        return vector / (np.linalg.norm(vector) or 1.0)

    def similarity(self, a: np.ndarray, b: np.ndarray) -> float:
        return float(np.dot(self.embedding(a), self.embedding(b)))

    def naturalness(self, samples: np.ndarray) -> float:
        if self.mos is None:
            self.mos = self._session(MOS_MODEL)
        window = int(MOS_WINDOW_S * RATE)
        scores, weights = [], []
        for start in range(0, len(samples), window):
            piece = samples[start:start + window]
            if len(piece) < RATE and scores:
                break  # a sub-second tail would add noise
            scores.append(float(self.mos.run(None, {"wave": piece[None].astype(np.float32)})[0][0]))
            weights.append(len(piece))
        return round(min(5.0, max(1.0, float(np.average(scores, weights=weights)))), 2)
