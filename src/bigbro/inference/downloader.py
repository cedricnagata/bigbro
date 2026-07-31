"""Fetches model weights to disk and reports progress against the catalog id.

Keyed by **catalog id**, never by repo id or display name: that is what the client
sent, what the router looks up, and what `modelDownloadProgress` is reported
against, so all three stay addressable by the same string. A download keyed by
anything else produces progress messages the client cannot match to its request.
"""

from __future__ import annotations

import asyncio
import logging
import shutil
import time
from dataclasses import dataclass
from pathlib import Path

from ..config import JSONStore, support_dir
from .catalog import BigBroModel

log = logging.getLogger("bigbro.download")

#: Minimum seconds between progress messages for one model. Hub callbacks fire per
#: chunk, which on a 12 GB model is thousands of messages a second onto the wire.
PROGRESS_INTERVAL = 0.5


@dataclass
class Progress:
    status: str
    bytes_completed: int = 0
    bytes_total: int = 0
    done: bool = False
    error: str | None = None

    @property
    def fraction(self) -> float:
        if self.bytes_total <= 0:
            return 0.0
        return min(1.0, self.bytes_completed / self.bytes_total)


class DownloadRecord:
    """Catalog id → the directory the weights landed in.

    Persisted because it is what makes removal possible across launches. BigBro never
    guesses at the Hub cache layout; the path is only ever one the downloader itself
    returned.
    """

    def __init__(self) -> None:
        self._store = JSONStore(support_dir() / "downloads.json")

    def path(self, model_id: str) -> Path | None:
        raw = self._store.get(model_id)
        return Path(raw) if isinstance(raw, str) else None

    def record(self, model_id: str, directory: Path) -> None:
        self._store.set(model_id, str(directory))

    def forget(self, model_id: str) -> None:
        self._store.delete(model_id)

    def is_downloaded(self, model_id: str) -> bool:
        """Whether the recorded directory still exists.

        Checks the filesystem rather than trusting a "was downloaded once" flag, so a
        Hub cache cleared behind bigbro's back reads as gone rather than as
        present-and-broken.
        """
        directory = self.path(model_id)
        return directory is not None and directory.exists()


def hub_repository_root(directory: Path) -> Path | None:
    """The repository directory to delete in order to actually reclaim a model's disk.

    The Hugging Face cache stores a model's bytes once and names them twice: the data
    lives in `<repo>/blobs/<etag>`, and `<repo>/snapshots/<commit>/<file>` is a tree
    of symlinks pointing into it. `snapshot_download` reports the *snapshot*
    directory, so deleting only that reclaims nothing — it removes the links and
    leaves every gigabyte of blob behind, and the next download relinks them without a
    byte crossing the network, which is indistinguishable from a remove that silently
    did nothing.

    Returns the repository root when the path really is a snapshot inside one.
    Anything shaped differently returns None and is deleted as-is — a path this cannot
    positively identify is not one to go deleting the parents of.
    """
    snapshots = directory.parent
    if snapshots.name != "snapshots":
        return None
    repository = snapshots.parent
    if not repository.name.startswith("models--"):
        return None
    return repository


def _snapshot(repo: str, on_bytes) -> Path:
    """Blocking Hub download. Runs in a worker thread — never on the event loop."""
    from huggingface_hub import snapshot_download

    class _ProgressTqdm:
        """Stands in for tqdm so huggingface_hub reports bytes without drawing bars.

        The Hub instantiates one of these per file and calls `update(n)` as bytes
        land; summing across instances is what gives a whole-model figure.
        """

        def __init__(self, *args, total=None, **kwargs):
            self.total = total or 0
            self.n = 0
            on_bytes(0, self.total, new_file=True)

        def update(self, n=1):
            self.n += n
            on_bytes(n, self.total, new_file=False)

        def close(self): ...
        def refresh(self): ...
        def set_description(self, *a, **k): ...
        def set_postfix(self, *a, **k): ...
        def __enter__(self): return self
        def __exit__(self, *a): self.close()

    return Path(snapshot_download(repo_id=repo, tqdm_class=_ProgressTqdm))


class ModelDownloader:
    """Coordinates downloads, de-duplicating concurrent requests for the same model."""

    def __init__(self, record: DownloadRecord | None = None) -> None:
        self.record = record or DownloadRecord()
        self._tasks: dict[str, asyncio.Task[Path]] = {}
        self._progress: dict[str, Progress] = {}
        #: Called with (model_id, Progress) on every throttled update. The daemon wires
        #: this to broadcast onto the peer connections.
        self.on_progress = None

    def is_downloading(self, model_id: str) -> bool:
        return model_id in self._tasks

    def progress(self, model_id: str) -> Progress | None:
        return self._progress.get(model_id)

    async def download(self, model: BigBroModel) -> Path:
        """Fetches weights to disk without materializing them into memory.

        Split from loading because they cost different things: downloading is
        bandwidth and disk, loading is RAM. Bundling them means pulling a 12 GB model
        also pins 12 GB of memory nobody asked to spend.
        """
        existing = self._tasks.get(model.id)
        if existing is not None:
            return await existing

        task = asyncio.create_task(self._run(model))
        self._tasks[model.id] = task
        try:
            return await task
        finally:
            self._tasks.pop(model.id, None)

    async def _run(self, model: BigBroModel) -> Path:
        loop = asyncio.get_running_loop()
        completed = 0
        total = 0
        last_emit = 0.0

        def on_bytes(delta: int, file_total: int, new_file: bool) -> None:
            # Called from the Hub's worker thread — hop back to the loop to emit.
            nonlocal completed, total, last_emit
            if new_file:
                total += file_total
                return
            completed += delta
            now = time.monotonic()
            if now - last_emit < PROGRESS_INTERVAL:
                return
            last_emit = now
            snapshot = Progress("downloading", completed, total)
            loop.call_soon_threadsafe(self._emit, model.id, snapshot)

        self._emit(model.id, Progress("starting", 0, 0))
        try:
            directory = await asyncio.to_thread(_snapshot, model.repo, on_bytes)
        except Exception as exc:
            log.error("download failed for %s: %s", model.id, exc)
            self._emit(model.id, Progress("error", completed, total, done=True, error=str(exc)))
            raise

        self.record.record(model.id, directory)
        log.info("downloaded %s to %s", model.id, directory)
        self._emit(model.id, Progress("complete", completed or total, total, done=True))
        return directory

    def remove(self, model: BigBroModel) -> None:
        """Deletes a model's weights from disk.

        A model whose path was never recorded has nothing safe to delete, so it is
        forgotten rather than guessed at, and the next download re-resolves it.
        """
        directory = self.record.path(model.id)
        if directory is None:
            log.info("remove %s: no recorded download path, nothing deleted", model.id)
            self.record.forget(model.id)
            return

        target = hub_repository_root(directory) or directory
        if target.exists():
            shutil.rmtree(target, ignore_errors=True)
            log.info("removed %s from %s", model.id, target)
        self.record.forget(model.id)

    def _emit(self, model_id: str, progress: Progress) -> None:
        self._progress[model_id] = progress
        if self.on_progress is not None:
            self.on_progress(model_id, progress)
