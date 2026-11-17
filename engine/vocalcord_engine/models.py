"""prepare: downloads the models the engine uses into the Hugging Face cache.

Each file streams into `<blob>.part` beside the cache's blobs, so a cancelled or
failed download resumes from the byte it reached (huggingface_hub deletes its own
partial files). huggingface_hub then links the finished blob into the snapshot,
as if it had downloaded the file itself.
"""

import os
from pathlib import Path
import threading
import time

from . import scoring, stt, tts

CHUNK = 1 << 20
REPORT_S = 0.25
_one_at_a_time = threading.Lock()  # two prepares would write the same .part files


def wanted(model: str) -> list[tuple[str, list[str]]]:
    """(repo, file patterns) for everything `model` needs. A Breeze copy under ~/voice/models counts as ready."""
    if model not in tts.MODELS:
        raise ValueError("model must be 8bit or 4bit")
    from mlx_audio.utils import DEFAULT_ALLOW_PATTERNS  # the files mlx-audio's loader takes from a repo

    local, repo = tts.MODELS[model]
    breeze = [] if Path(local).expanduser().is_dir() else [(repo, DEFAULT_ALLOW_PATTERNS)]
    return breeze + [
        (stt.MODEL, DEFAULT_ALLOW_PATTERNS),
        (scoring.SPEAKER_MODEL[0], [scoring.SPEAKER_MODEL[1]]),
        (scoring.MOS_MODEL[0], [scoring.MOS_MODEL[1]]),
    ]


def prepare(model: str, progress=lambda **_: None, check=lambda: None) -> dict:
    """Download whatever `model` needs that the cache lacks, reporting bytes done of the bytes missing."""
    from huggingface_hub import HfApi, try_to_load_from_cache
    from huggingface_hub.utils import filter_repo_objects

    with _one_at_a_time:
        files = []  # (repo, filename, size) not in the cache yet
        for repo, patterns in wanted(model):
            check()
            progress(stage="list", repo=repo)
            info = HfApi().model_info(repo, files_metadata=True)
            for sibling in filter_repo_objects(info.siblings, allow_patterns=patterns, key=lambda s: s.rfilename):
                if not isinstance(try_to_load_from_cache(repo, sibling.rfilename, revision=info.sha), str):
                    files.append((repo, sibling.rfilename, sibling.size or 0))
        total = sum(size for _, _, size in files)
        done = 0
        last = 0.0

        def report(name, have, force=False):
            nonlocal last
            if force or time.monotonic() - last >= REPORT_S:
                last = time.monotonic()
                progress(stage="download", done=done + have, total=total, file=name)

        report(None, 0, force=True)
        for repo, filename, size in files:
            name = f"{repo}/{filename}"
            fetch(repo, filename, lambda have: report(name, have), check)
            done += size
            report(name, 0, force=True)
        return {"downloaded": total}


def fetch(repo: str, filename: str, on_bytes=lambda have: None, check=lambda: None) -> str:
    """Download one file into the cache and return its path."""
    from huggingface_hub import get_hf_file_metadata, hf_hub_download, hf_hub_url
    from huggingface_hub.constants import HF_HUB_CACHE
    from huggingface_hub.file_download import repo_folder_name

    meta = get_hf_file_metadata(hf_hub_url(repo, filename))
    blob = Path(HF_HUB_CACHE) / repo_folder_name(repo_id=repo, repo_type="model") / "blobs" / meta.etag
    if not blob.exists():
        part = blob.with_name(blob.name + ".part")
        download(meta.location, part, meta.size, on_bytes, check)
        os.replace(part, blob)
    return hf_hub_download(repo, filename)  # finds the blob, links it into the snapshot, records the revision


def download(url: str, part: Path, size: int | None, on_bytes=lambda have: None, check=lambda: None) -> None:
    """Stream `url` into `part`, continuing from the bytes `part` already holds. `check` raises to cancel."""
    from huggingface_hub.utils import get_session

    part.parent.mkdir(parents=True, exist_ok=True)
    have = part.stat().st_size if part.exists() else 0
    if size is None or have > size:
        have = 0
    if have != size:
        headers = {"Accept-Encoding": "identity"}
        if have:
            headers["Range"] = f"bytes={have}-"
        with get_session().stream("GET", url, headers=headers, follow_redirects=True, timeout=30) as response:
            response.raise_for_status()
            if response.status_code != 206:
                have = 0  # the server sent the whole file
            with part.open("r+b" if have else "wb") as out:
                out.seek(have)
                out.truncate()
                for chunk in response.iter_bytes(CHUNK):
                    check()
                    out.write(chunk)
                    have += len(chunk)
                    on_bytes(have)
    if size is not None and have != size:
        raise OSError(f"The download of {part.name} stopped at {have} of {size} bytes")
