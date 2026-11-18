"""Protocol round trip over pipes with a fake backend (no models)."""

import json
import os
import threading
import time

from vocalcord_engine import worker


class FakeEngine:
    def __init__(self):
        self.release = threading.Event()
        self.idle_ticks = 0

    def status(self):
        return {"large_model": None, "small_models": []}

    def idle_tick(self):
        self.idle_ticks += 1

    def touch(self):
        pass

    def render(self, request, job):
        for index, _ in enumerate(request["lines"]):
            job.check()                      # cancellation point between lines
            job.progress(stage="render", done=index + 1, total=len(request["lines"]))
            self.release.wait(5)
        return {"path": request["output"]}

    def transcribe(self, request, job):
        if not request.get("audio"):
            raise ValueError("audio (a file path) is required")
        return {"text": "hello", "words": [{"word": "hello", "start": 0.0, "end": 0.4}]}

    def score(self, request, job):
        raise RuntimeError("boom")

    def check_audio(self, request, job):
        return {"duration": 1.0, "warnings": []}

    def edit_clip(self, request, job):
        return {"path": request["out"], "duration": 1.0}

    def split(self, request, job):
        return {"clips": []}

    def unload(self, request, job):
        return {"unloaded": True}

    def prepare(self, request, job):
        done = 0
        while True:
            job.check()                      # cancellation point between chunks
            done += 1
            job.progress(stage="download", done=done, total=10)
            time.sleep(0.01)


class Session:
    def __init__(self, engine):
        read_in, self._write_in = os.pipe()
        self._read_out, write_out = os.pipe()
        self.requests = os.fdopen(self._write_in, "w", buffering=1)
        self.replies = os.fdopen(self._read_out, "r")
        self.thread = threading.Thread(
            target=worker.serve,
            args=(engine, os.fdopen(read_in, "r"), os.fdopen(write_out, "w", buffering=1), 0.05),
            daemon=True)
        self.thread.start()

    def send(self, **request):
        self.requests.write(json.dumps(request) + "\n")

    def read(self):
        return json.loads(self.replies.readline())

    def until(self, job_id, event):
        while True:
            message = self.read()
            if message["id"] == job_id and message["event"] == event:
                return message


def test_round_trip():
    engine = FakeEngine()
    s = Session(engine)

    s.send(id=1, cmd="ping")
    assert s.read() == {"id": 1, "event": "result", "pong": True, "version": worker.__version__}

    s.send(id=2, cmd="transcribe", audio="x.wav")
    assert s.read() == {"id": 2, "event": "result", "text": "hello",
                        "words": [{"word": "hello", "start": 0.0, "end": 0.4}]}

    s.send(id=3, cmd="transcribe")
    assert s.read() == {"id": 3, "event": "error", "code": "invalid", "message": "audio (a file path) is required"}

    s.send(id=4, cmd="score", audio="a", reference="b", text="c")
    assert s.read() == {"id": 4, "event": "error", "code": "failed", "message": "RuntimeError: boom"}

    s.send(id=5, cmd="dance")
    assert s.read()["code"] == "invalid"
    s.requests.write("not json\n")
    assert s.read()["id"] is None

    # A running render: status shows it busy, check_audio still answers, cancel stops it between lines.
    s.send(id="r", cmd="render", output="out.wav", lines=[{}, {}, {}])
    assert s.read() == {"id": "r", "event": "progress", "stage": "render", "done": 1, "total": 3}
    s.send(id=6, cmd="status")
    status = s.read()
    assert status["busy"] == "r" and status["large_model"] is None
    s.send(id=7, cmd="check_audio", audio="x.wav")
    assert s.read() == {"id": 7, "event": "result", "duration": 1.0, "warnings": []}
    s.send(id=8, cmd="cancel", target="r")
    assert s.read() == {"id": 8, "event": "result", "cancelled": True}
    engine.release.set()
    assert s.until("r", "error") == {"id": "r", "event": "error", "code": "cancelled", "message": "Cancelled"}

    s.send(id=9, cmd="cancel", target="nothing")
    assert s.read()["cancelled"] is False

    # Without a cancel the render completes; the idle timer keeps ticking between jobs.
    s.send(id="r2", cmd="render", output="out2.wav", lines=[{}, {}])
    assert s.until("r2", "result") == {"id": "r2", "event": "result", "path": "out2.wav"}
    time.sleep(0.2)
    assert engine.idle_ticks > 0

    s.send(id=10, cmd="shutdown")
    assert s.read() == {"id": 10, "event": "result", "shutdown": True}
    s.thread.join(2)
    assert not s.thread.is_alive()


def test_stdin_closing_stops_the_worker():
    s = Session(FakeEngine())
    s.requests.close()
    s.thread.join(2)
    assert not s.thread.is_alive()


def test_prepare_runs_beside_the_queue_and_cancels():
    engine = FakeEngine()
    s = Session(engine)
    s.send(id="r", cmd="render", output="out.wav", lines=[{}])
    s.until("r", "progress")
    s.send(id="p", cmd="prepare", model="4bit")
    assert s.until("p", "progress")["stage"] == "download"   # not queued behind the render
    s.send(id=1, cmd="cancel", target="p")
    assert s.until(1, "result")["cancelled"] is True
    assert s.until("p", "error")["code"] == "cancelled"
    engine.release.set()
    assert s.until("r", "result")["path"] == "out.wav"


def test_edit_clip_answers_while_a_render_runs():
    engine = FakeEngine()
    s = Session(engine)
    s.send(id="r", cmd="render", output="out.wav", lines=[{}])
    s.until("r", "progress")
    s.send(id="e", cmd="edit_clip", audio="a.wav", out="e.wav")
    # The next reply, while the render is still held: had it queued, the render's result would come first.
    assert s.read() == {"id": "e", "event": "result", "path": "e.wav", "duration": 1.0}
    engine.release.set()
    assert s.until("r", "result")["path"] == "out.wav"
