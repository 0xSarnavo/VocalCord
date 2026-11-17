"""prepare's offline parts: what it fetches, and resumable, cancellable downloads from a local server."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading

import pytest

from vocalcord_engine import models, scoring, stt, tts

DATA = bytes(range(256)) * 1200  # 300 KB


@pytest.fixture
def server():
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.headers.get("Range"))
            start = 0
            if self.server.honour_range and self.headers.get("Range"):
                start = int(self.headers["Range"].removeprefix("bytes=").rstrip("-"))
            self.send_response(206 if start else 200)
            self.send_header("Content-Length", str(len(DATA) - start))
            self.end_headers()
            self.wfile.write(DATA[start:])

        def log_message(self, *args):
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    httpd.honour_range = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield httpd, f"http://127.0.0.1:{httpd.server_address[1]}/file", requests
    httpd.shutdown()


def test_wanted_lists_every_model_and_skips_a_local_breeze(tmp_path, monkeypatch):
    monkeypatch.setitem(tts.MODELS, "4bit", (str(tmp_path / "missing"), "org/breeze-4bit"))
    repos = [repo for repo, _ in models.wanted("4bit")]
    assert repos == ["org/breeze-4bit", stt.MODEL, scoring.SPEAKER_MODEL[0], scoring.MOS_MODEL[0]]

    monkeypatch.setitem(tts.MODELS, "4bit", (str(tmp_path), "org/breeze-4bit"))
    assert [repo for repo, _ in models.wanted("4bit")] == repos[1:]

    with pytest.raises(ValueError):
        models.wanted("/some/folder")


def test_download_resumes_a_part_file(tmp_path, server):
    _, url, requests = server
    part = tmp_path / "blob.part"
    part.write_bytes(DATA[:100_000])
    seen = []
    models.download(url, part, len(DATA), seen.append)
    assert part.read_bytes() == DATA
    assert requests == ["bytes=100000-"]
    assert seen[-1] == len(DATA)


def test_cancel_keeps_the_bytes_for_next_time(tmp_path, server, monkeypatch):
    _, url, requests = server
    monkeypatch.setattr(models, "CHUNK", 64 * 1024)
    part = tmp_path / "blob.part"
    calls = []

    def check():
        calls.append(1)
        if len(calls) == 3:
            raise RuntimeError("cancelled")

    with pytest.raises(RuntimeError):
        models.download(url, part, len(DATA), check=check)
    assert part.stat().st_size == 2 * 64 * 1024
    models.download(url, part, len(DATA))
    assert part.read_bytes() == DATA
    assert requests == [None, f"bytes={2 * 64 * 1024}-"]


def test_a_server_ignoring_range_starts_over(tmp_path, server):
    httpd, url, _ = server
    httpd.honour_range = False
    part = tmp_path / "blob.part"
    part.write_bytes(b"x" * 1000)
    models.download(url, part, len(DATA))
    assert part.read_bytes() == DATA


def test_a_short_download_is_an_error(tmp_path, server):
    _, url, _ = server
    with pytest.raises(OSError):
        models.download(url, tmp_path / "blob.part", len(DATA) + 1)
