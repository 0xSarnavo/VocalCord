"""JSON-lines worker on stdin/stdout. See PROTOCOL.md.

The reader thread answers ping, status, cancel and shutdown at once, runs
check_audio, edit_clip, apply_marks and prepare on their own threads, and queues every other command for a single job
thread, which owns all MLX work. Only one large model (Breeze or Whisper) is in
memory at a time; it is unloaded after IDLE_S seconds without use.
"""

import ctypes
import gc
import json
import logging
import os
from pathlib import Path
import queue
import resource
import sys
import tempfile
import threading
import time

from . import __version__, audio

log = logging.getLogger("vocalcord_engine")

IDLE_S = 120.0
# MLX keeps freed buffers for reuse; uncapped that cache reached 2.2 GB with Breeze
# 4-bit and made renders twice as slow on 8 GB through swapping (README).
MLX_CACHE_LIMIT = 256 * 2**20
JOB_COMMANDS = {"transcribe", "render", "score", "time_words", "split", "group_speakers", "mix", "unload"}
# Run at once on their own threads: none touches MLX, a timeline edit or a script mark must not wait for a render,
# and a long download must not hold up renders.
SIDE_COMMANDS = {"check_audio", "edit_clip", "apply_marks", "prepare"}


class Cancelled(Exception):
    pass


def memory() -> dict:
    """Process memory in MB. footprint is what Activity Monitor shows and includes
    MLX's Metal buffers; rss alone undercounts them."""
    info = (ctypes.c_uint64 * 64)()
    result = {"peak_rss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20)}
    try:
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        if libc.proc_pid_rusage(os.getpid(), 4, ctypes.byref(info)) == 0:
            # rusage_info_v4: 16-byte uuid, then uint64 fields.
            fields = info[2:]
            result.update(rss_mb=round(fields[6] / 2**20), footprint_mb=round(fields[7] / 2**20),
                          peak_footprint_mb=round(fields[28] / 2**20))
    except (OSError, AttributeError):
        pass
    return result


class Engine:
    """The real backend. Every method except status and the SIDE_COMMANDS runs on the job thread."""

    def __init__(self):
        import mlx.core as mx
        from .scoring import Scorer

        mx.set_cache_limit(MLX_CACHE_LIMIT)
        self.large = None        # (key, model)
        self.scorer = Scorer()
        self.last_used = time.monotonic()

    # --- memory -------------------------------------------------------------

    def _drop_large(self) -> None:
        if self.large is None:
            return
        log.info("unloading %s", self.large[0])
        self.large = None
        gc.collect()
        import mlx.core as mx
        mx.clear_cache()

    def _model(self, key: str, loader, progress):
        if self.large and self.large[0] == key:
            return self.large[1]
        self._drop_large()
        progress(stage="load", model=key)
        started = time.monotonic()
        model = loader()
        log.info("loaded %s in %.1f s", key, time.monotonic() - started)
        self.large = (key, model)
        return model

    def _tts(self, path: str, progress):
        def loader():
            from mlx_audio.tts import load
            # Breeze needs every MB on 8 GB; the scoring models reload in about a second.
            self.scorer.unload()
            gc.collect()
            return load(path)
        return self._model(f"breeze:{path}", loader, progress)

    def _stt(self, progress):
        from . import stt
        return self._model(f"whisper:{stt.MODEL}", stt.load, progress)

    def idle_tick(self) -> None:
        if self.large and time.monotonic() - self.last_used >= IDLE_S:
            self._drop_large()

    def touch(self) -> None:
        self.last_used = time.monotonic()

    def status(self) -> dict:
        large = self.large
        return {"large_model": large[0] if large else None, "small_models": self.scorer.loaded(), **memory()}

    def unload(self, request, job) -> dict:
        self._drop_large()
        self.scorer.unload()
        gc.collect()
        return {"unloaded": True}

    # --- commands -----------------------------------------------------------

    def check_audio(self, request, job) -> dict:
        return audio.check_audio(_path(request, "audio"))

    def edit_clip(self, request, job) -> dict:
        from . import edit
        return edit.edit_clip(request, job.check)

    def apply_marks(self, request, job) -> dict:
        from . import marks
        return marks.apply_marks(request, job.check)

    def prepare(self, request, job) -> dict:
        from . import models
        return models.prepare(str(request.get("model", "")), job.progress, job.check)

    def transcribe(self, request, job) -> dict:
        from . import stt
        source = _path(request, "audio")
        with tempfile.TemporaryDirectory() as temp:
            wav = Path(temp) / "16k.wav"
            audio.decode(source, {wav: stt.RATE})
            model = self._stt(job.progress)
            return stt.transcribe_file(model, wav, job.progress, job.check)

    def split(self, request, job) -> dict:
        import soundfile as sf
        from . import clips, stt

        source = _path(request, "audio")
        if not request.get("out_dir"):
            raise ValueError("out_dir is required")
        out_dir = Path(str(request["out_dir"])).expanduser()
        min_s = float(request.get("min_s", clips.MIN_S))
        max_s = float(request.get("max_s", clips.MAX_S))
        shorter, longer = clips.EDGE_SLACK
        if not 0 < min_s + shorter < max_s - longer:
            raise ValueError("max_s must be more than min_s + 0.7")
        with tempfile.TemporaryDirectory() as temp:
            wav16 = Path(temp) / "16k.wav"
            native = Path(temp) / "native.wav"
            audio.decode(source, {wav16: stt.RATE, native: None})
            model = self._stt(job.progress)
            transcript = stt.transcribe_file(model, wav16, job.progress, job.check)
            words, duration = transcript["words"], transcript["duration"]
            # Plan inside the limits so edge refinement cannot push a clip outside them.
            planned = clips.plan_clips(words, duration, min_s + shorter, max_s - longer)
            out_dir.mkdir(parents=True, exist_ok=True)
            written = []
            with sf.SoundFile(str(wav16)) as src16, sf.SoundFile(str(native)) as src:
                def read16(t0, t1):
                    first = max(0, int(t0 * stt.RATE))
                    src16.seek(first)
                    return src16.read(max(0, int(t1 * stt.RATE) - first), dtype="float32")

                for clip in planned:
                    job.check()
                    start, end = clips.refine_edges(clip, words, read16, stt.RATE, duration)
                    if not min_s <= end - start <= max_s:
                        continue
                    src.seek(int(start * src.samplerate))
                    samples = src.read(int((end - start) * src.samplerate), dtype="int16")
                    path = out_dir / f"clip-{len(written) + 1:03d}.wav"
                    sf.write(str(path), samples, src.samplerate, subtype="PCM_16")
                    written.append({"path": str(path), "start": start, "end": end,
                                    "duration": round(end - start, 3), "text": clip["text"]})
        return {"text": transcript["text"], "duration": duration, "clips": written}

    def group_speakers(self, request, job) -> dict:
        from . import scoring
        clips = request.get("clips")
        if not isinstance(clips, list) or not all(isinstance(path, str) and path for path in clips):
            raise ValueError("clips (a list of file paths) is required")
        threshold = float(request.get("threshold", scoring.SAME_SPEAKER))
        vectors = []
        for index, path in enumerate(clips):
            job.check()
            vectors.append(self.scorer.embedding(audio.read_mono(path, scoring.RATE)))
            job.progress(stage="embed", done=index + 1, total=len(clips))
        return {"groups": [[clips[index] for index in group] for group in scoring.group_speakers(vectors, threshold)]}

    def render(self, request, job) -> dict:
        from . import tts
        prepared = tts.prepare(request)
        model = self._tts(prepared["model"], job.progress)
        return tts.render(model, prepared, job.progress, job.check)

    def mix(self, request, job) -> dict:
        from . import mix
        return mix.mix(request, job.progress, job.check)

    def score(self, request, job) -> dict:
        from . import align, scoring, stt
        text = request.get("text")
        if not isinstance(text, str) or not text.strip():
            raise ValueError("text (the script line) is required")
        hints = _hints(request)
        tokens = None if request.get("tokens") is None else align.parse_tokens(request["tokens"])
        start, end = request.get("start"), request.get("end")
        render = audio.read_mono(_path(request, "audio"), scoring.RATE, start, end)
        reference = audio.read_mono(_path(request, "reference"), scoring.RATE)
        if len(render) < scoring.RATE // 2:
            raise ValueError("The audio to score is shorter than half a second")
        model = self._stt(job.progress)
        heard = stt.transcribe_array(model, render, words=tokens is not None, prompt=stt.hint_prompt(hints))
        similarity = self.scorer.similarity(render, reference)
        result = {
            "like_you": scoring.like_you(similarity),
            "human": self.scorer.naturalness(render),
            "words": scoring.words_right(text, heard["text"]),
            "heard": heard["text"],
            "similarity": round(similarity, 4),
            "pitch_hz": scoring.pitch(render),
            "reference_pitch_hz": scoring.pitch(reference),
            "longest_pause": scoring.longest_pause(render),
        }
        if tokens is not None:
            result.update(align.align(tokens, heard["words"], render, scoring.RATE))
        return result

    def time_words(self, request, job) -> dict:
        """Word times for a render made before score returned them: score's transcript and alignment, no scores."""
        from . import align, scoring, stt
        tokens = align.parse_tokens(request.get("tokens"))
        if not tokens:
            raise ValueError("tokens (the script's words) is required")
        hints = _hints(request)
        samples = audio.read_mono(_path(request, "audio"), scoring.RATE, request.get("start"), request.get("end"))
        model = self._stt(job.progress)
        heard = stt.transcribe_array(model, samples, words=True, prompt=stt.hint_prompt(hints))
        return {"heard": heard["text"], **align.align(tokens, heard["words"], samples, scoring.RATE)}


def _hints(request: dict) -> list[str]:
    hints = request.get("hints") or []
    if not isinstance(hints, list) or not all(isinstance(hint, str) for hint in hints):
        raise ValueError("hints must be a list of words")
    return hints


def _path(request: dict, key: str) -> str:
    value = request.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} (a file path) is required")
    return value


class Job:
    def __init__(self, job_id, send, is_cancelled):
        self.id = job_id
        self._send = send
        self._is_cancelled = is_cancelled

    def progress(self, **fields) -> None:
        self._send({"id": self.id, "event": "progress", **fields})

    def check(self) -> None:
        if self._is_cancelled(self.id):
            raise Cancelled()


def serve(engine, stdin, stdout, idle_poll: float = 5.0) -> None:
    lock = threading.Lock()
    jobs: queue.Queue = queue.Queue()
    cancelled: set = set()
    side: set = set()  # ids of SIDE_COMMANDS jobs still running
    state = {"running": None, "stopping": False}

    def send(message: dict) -> None:
        line = json.dumps(message, ensure_ascii=False)
        with lock:
            stdout.write(line + "\n")
            stdout.flush()

    def is_cancelled(job_id) -> bool:
        return state["stopping"] or job_id in cancelled

    def run(job_id, cmd, request) -> None:
        job = Job(job_id, send, is_cancelled)
        try:
            job.check()
            result = getattr(engine, cmd)(request, job)
            send({"id": job_id, "event": "result", **result})
        except Cancelled:
            send({"id": job_id, "event": "error", "code": "cancelled", "message": "Cancelled"})
        except ValueError as error:
            send({"id": job_id, "event": "error", "code": "invalid", "message": str(error)})
        except Exception as error:  # report, keep serving
            log.exception("%s failed", cmd)
            send({"id": job_id, "event": "error", "code": "failed", "message": f"{type(error).__name__}: {error}"})
        finally:
            cancelled.discard(job_id)

    def job_loop() -> None:
        while True:
            try:
                item = jobs.get(timeout=idle_poll)
            except queue.Empty:
                engine.idle_tick()
                continue
            if item is None:
                return
            state["running"] = item[0]
            try:
                run(*item)
            finally:
                state["running"] = None
                engine.touch()

    worker = threading.Thread(target=job_loop, name="jobs", daemon=True)
    worker.start()

    def stop() -> None:
        state["stopping"] = True
        jobs.put(None)
        worker.join()

    for raw in stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            request = json.loads(raw)
            if not isinstance(request, dict):
                raise ValueError("a request must be a JSON object")
        except ValueError as error:
            send({"id": None, "event": "error", "code": "invalid", "message": f"Bad JSON: {error}"})
            continue
        job_id, cmd = request.get("id"), request.get("cmd")
        if cmd == "ping":
            send({"id": job_id, "event": "result", "pong": True, "version": __version__})
        elif cmd == "status":
            send({"id": job_id, "event": "result", "busy": state["running"], "queued": jobs.qsize(),
                  "idle_unload_s": IDLE_S, **engine.status()})
        elif cmd == "cancel":
            target = request.get("target")
            known = target is not None and (target == state["running"] or target in side or
                                            any(item and item[0] == target for item in list(jobs.queue)))
            if known:
                cancelled.add(target)
            send({"id": job_id, "event": "result", "cancelled": known})
        elif cmd == "shutdown":
            stop()
            send({"id": job_id, "event": "result", "shutdown": True})
            return
        elif cmd in SIDE_COMMANDS:
            side.add(job_id)

            def run_side(job_id=job_id, cmd=cmd, request=request):
                try:
                    run(job_id, cmd, request)
                finally:
                    side.discard(job_id)

            threading.Thread(target=run_side, daemon=True).start()
        elif cmd in JOB_COMMANDS:
            jobs.put((job_id, cmd, request))
        else:
            send({"id": job_id, "event": "error", "code": "invalid", "message": f"Unknown command: {cmd}"})
    stop()  # stdin closed: the app has gone


def main() -> None:
    logging.basicConfig(stream=sys.stderr, level=os.environ.get("VOCALCORD_LOG", "INFO"),
                        format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("httpx2").setLevel(logging.WARNING)
    # Keep the protocol channel clean: anything a library prints (even from C) goes to stderr.
    protocol = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    log.info("vocalcord engine %s ready (pid %d)", __version__, os.getpid())
    serve(Engine(), sys.stdin, protocol)
