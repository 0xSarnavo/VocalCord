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


# --- speakers ------------------------------------------------------------

# Two groups join while their average clip-to-clip cosine is at least this: other speakers
# score up to about 0.22 (above), clips of one speaker well over 0.5.
SAME_SPEAKER = 0.5
# Groups under this share of the clips (and never under 2 clips) are strays, such as laughter,
# music, or someone saying one word; they are left out of the result.
MIN_GROUP_SHARE = 0.05


def group_speakers(vectors, threshold: float = SAME_SPEAKER) -> list[list[int]]:
    """Average-linkage agglomerative clustering of unit speaker embeddings by cosine similarity.
    Returns groups of row indices, largest first; stray groups are dropped, but the largest is always kept."""
    n = len(vectors)
    if n == 0:
        return []
    matrix = np.asarray(vectors, dtype=np.float64)
    similarity = matrix @ matrix.T
    np.fill_diagonal(similarity, -np.inf)
    groups = [[i] for i in range(n)]
    sizes = np.ones(n)
    active = np.ones(n, dtype=bool)
    for _ in range(n - 1):
        masked = np.where(active[:, None] & active[None, :], similarity, -np.inf)
        i, j = np.unravel_index(np.argmax(masked), masked.shape)
        if masked[i, j] < threshold:
            break
        # Lance-Williams update for average linkage: the merged group's mean similarity to every other group.
        similarity[i] = (similarity[i] * sizes[i] + similarity[j] * sizes[j]) / (sizes[i] + sizes[j])
        similarity[:, i] = similarity[i]
        similarity[i, i] = -np.inf
        sizes[i] += sizes[j]
        active[j] = False
        groups[i] += groups[j]
    found = sorted((sorted(groups[k]) for k in range(n) if active[k]), key=lambda g: (-len(g), g[0]))
    smallest = max(2, int(np.ceil(MIN_GROUP_SHARE * n)))
    return [found[0]] + [group for group in found[1:] if len(group) >= smallest]


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


# --- delivery: pitch and gaps ----------------------------------------------

def _frames(samples: np.ndarray, size: int, hop: int) -> np.ndarray:
    count = max(0, 1 + (len(samples) - size) // hop)
    return np.stack([samples[i * hop:i * hop + size] for i in range(count)]) if count else np.zeros((0, size))


def pitch(samples: np.ndarray, rate: int = RATE) -> float:
    """Median pitch in Hz of the voiced 40 ms frames (autocorrelation, 70-400 Hz), or 0 with none. Compared with the
    take's, it catches a render that drifts into a higher or lower voice, as a Happy direction once did by 6 semitones."""
    size = int(0.04 * rate)
    frames = _frames(samples.astype(np.float64), size, size // 2)
    if not len(frames):
        return 0.0
    frames = frames - frames.mean(axis=1, keepdims=True)
    loud = np.sqrt(np.mean(frames ** 2, axis=1)) >= np.max(np.abs(samples)) * 0.05
    frames = frames[loud]
    if not len(frames):
        return 0.0
    spectrum = np.fft.rfft(frames, 2 * size, axis=1)
    corr = np.fft.irfft(np.abs(spectrum) ** 2, axis=1)[:, :size]
    low, high = int(rate / 400), int(rate / 70)
    lags = low + np.argmax(corr[:, low:high], axis=1)
    voiced = corr[np.arange(len(lags)), lags] > 0.5 * corr[:, 0]
    return round(float(np.median(rate / lags[voiced])), 1) if voiced.any() else 0.0


def longest_pause(samples: np.ndarray, rate: int = RATE) -> float:
    """Longest stretch inside the audio (not at its ends) of 20 ms frames 40 dB under the speech level, in seconds."""
    frames = _frames(samples.astype(np.float64), int(0.02 * rate), int(0.02 * rate))
    if len(frames) < 3:
        return 0.0
    level = 20 * np.log10(np.sqrt(np.mean(frames ** 2, axis=1)) + 1e-9)
    quiet = level < np.percentile(level, 95) - 40
    loud = np.flatnonzero(~quiet)
    if not len(loud):
        return 0.0
    longest = run = 0
    for q in quiet[loud[0]:loud[-1] + 1]:
        run = run + 1 if q else 0
        longest = max(longest, run)
    return round(longest * 0.02, 2)


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
