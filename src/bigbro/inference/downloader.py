"""Fetches model weights to disk and reports progress against the catalog id.

Keyed by **catalog id**, never by repo id or display name: that is what the client
sent, what the router looks up, and what `modelDownloadProgress` is reported
against, so all three stay addressable by the same string. A download keyed by
anything else produces progress messages the client cannot match to its request.
"""

from __future__ import annotations

import asyncio
import logging
import pathlib
import shutil
import time
from fnmatch import fnmatch
from dataclasses import dataclass
from pathlib import Path

from ..config import JSONStore, support_dir
from .catalog import BigBroModel, Family

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

    #: Keys written before speech models became catalog entries.
    LEGACY_KEYS = {"speech.tts": "kokoro", "speech.stt": "parakeet"}

    def __init__(self) -> None:
        self._store = JSONStore(support_dir() / "downloads.json")
        self._migrate_legacy_keys()

    def _migrate_legacy_keys(self) -> None:
        """Renames records written under the old `speech.tts` / `speech.stt` keys.

        Without this a Mac that already has Parakeet on disk reads as not having
        it and silently re-downloads 2.5 GB, because nothing looks up the old key
        any more.
        """
        for legacy, current in self.LEGACY_KEYS.items():
            path = self._store.get(legacy)
            if path is None:
                continue
            if self._store.get(current) is None and pathlib.Path(path).exists():
                self._store.set(current, path)
                log.info("migrated download record %s -> %s", legacy, current)
            self._store.delete(legacy)

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


class _DevNull:
    """Where the Hub's progress bars are pointed.

    stdout belongs to the dashboard, and under `--no-ui` a redrawing bar would
    interleave with the log stream. `isatty()` is False so tqdm picks its
    non-interactive path and does not emit control sequences either.
    """

    def write(self, *_args) -> int:
        return 0

    def flush(self) -> None: ...

    def isatty(self) -> bool:
        return False


# What each loader actually fetches. Copied from `mlx_lm.utils.get_model_path` and
# `mlx_vlm.utils.get_model_path` so bigbro downloads the same files MLX will look
# for — no more, so a repo that also ships original PyTorch weights or a GGUF
# conversion does not cost gigabytes nothing will ever read.
#
# They must also be applied when sizing the repo. A total that counts files the
# download skips is a progress bar that can never reach 100%.
LANGUAGE_PATTERNS = (
    "*.json", "model*.safetensors", "*.py", "tokenizer.model",
    "*.tiktoken", "tiktoken.model", "*.txt", "*.jsonl", "*.jinja",
)
VISION_PATTERNS = (
    "*.json", "*.safetensors", "*.py", "*.model", "*.tiktoken", "*.txt", "*.jinja",
)
# Speech needs its own set, and getting it from the language list is what broke
# these entirely: Kokoro's weights are `kokoro-v1_0.safetensors`, which
# `model*.safetensors` does not match, and its `voices/` embeddings match nothing
# at all — so the download fetched 2 KB of config and reported itself complete.
#
# Taken from mlx_audio's own file list, plus the tokenizer files Parakeet needs.
# `*.safetensors` and `*.pt` match at any depth, which is what picks up `voices/`.
# The only thing deliberately left behind is Kokoro's `.pth`, a 327 MB PyTorch
# copy of weights already fetched as safetensors.
SPEECH_PATTERNS = (
    "*.json", "*.safetensors", "*.pt", "*.py", "*.txt",
    "*.yaml", "*.jinja", "*.model", "*.vocab", "*.wav",
)


def patterns_for(model: BigBroModel) -> list[str]:
    """The `allow_patterns` the loader for this model's family would use."""
    if model.family.is_speech:
        return list(SPEECH_PATTERNS)
    if model.family is Family.VISION:
        return list(VISION_PATTERNS)
    return list(LANGUAGE_PATTERNS)


def repo_total_bytes(repo: str, patterns: list[str] | None = None) -> int:
    """The download's size, from the Hub's own file metadata.

    Asked for up front rather than inferred from the progress bars, because
    `snapshot_download` instantiates `tqdm_class` for three different things: two
    byte counters and one bar that counts *files*. Adding their totals together
    mixes units and yields a "total" of 8 — which reads as 100% complete from the
    first byte. The API knows the real answer, so ask it.

    Counts only the files `patterns` would fetch, so the total and the progress
    against it describe the same download.
    """
    try:
        from huggingface_hub import HfApi

        info = HfApi().model_info(repo, files_metadata=True)
        siblings = info.siblings or []
        if patterns:
            siblings = [
                s for s in siblings
                if any(fnmatch(getattr(s, "rfilename", ""), p) for p in patterns)
            ]
        return sum(int(getattr(s, "size", 0) or 0) for s in siblings)
    except Exception as exc:  # network, auth, renamed repo
        log.warning("could not size %s up front: %s", repo, exc)
        return 0


def _snapshot(repo: str, patterns: list[str], on_progress) -> Path:
    """Blocking Hub download. Runs in a worker thread — never on the event loop.

    `on_progress(furthest_bytes)` is called as the Hub reports. It receives an
    absolute figure rather than a delta — see `_ProgressTqdm` for why summing is
    wrong here.
    """
    from huggingface_hub import snapshot_download
    from huggingface_hub.utils.tqdm import tqdm as hf_tqdm

    #: Bar identity → bytes that bar has counted.
    counters: dict[int, int] = {}

    class _ProgressTqdm(hf_tqdm):
        """Reports Hub progress without drawing anything.

        Subclasses the Hub's own tqdm rather than duck-typing one. The Hub calls a
        wide slice of the tqdm API on whatever it is given — `set_postfix_str`,
        `format_dict`, `reset` — and a hand-rolled stand-in raises AttributeError
        from inside its worker threads the moment it touches one that was missed.

        `snapshot_download` creates three of these: two byte counters and one that
        counts *files*. Only the byte ones are watched, and the furthest along is
        taken rather than their sum — both report the same transfer from different
        ends (network vs. reconstruction), so adding them double-counts, while the
        one that finishes is the one that reaches the real total.
        """

        def __init__(self, *args, **kwargs):
            # `unit` and the running count are kept here rather than read off tqdm,
            # because the Hub decides for itself whether bars are disabled (log
            # level, HF_HUB_DISABLE_PROGRESS_BARS) and a disabled tqdm
            # short-circuits its own __init__: `unit` is never assigned and
            # `update()` returns without advancing `n`. Reading either would raise
            # AttributeError from inside the Hub's worker threads, which surfaces
            # as a failed download rather than a missing progress bar.
            self._byte_unit = kwargs.get("unit") == "B"
            self._counted = int(kwargs.get("initial") or 0)
            kwargs["file"] = _DevNull()
            super().__init__(*args, **kwargs)

        def update(self, n=1):
            self._counted += int(n or 0)
            if self._byte_unit:
                counters[id(self)] = self._counted
                on_progress(max(counters.values()))
            return super().update(n)

    return Path(
        snapshot_download(repo_id=repo, allow_patterns=patterns, tqdm_class=_ProgressTqdm)
    )


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

        # Already on disk: nothing to fetch, and nothing to announce. Going
        # through the full flow anyway cost a network round trip to size the repo
        # on every single model start — which broadcast a spurious "downloading"
        # to every connected device, and hung outright when the Hub was slow or
        # unreachable, for a model that was sitting on disk the whole time.
        recorded = self.record.path(model.id)
        if recorded is not None and recorded.exists():
            return recorded

        task = asyncio.create_task(self._run(model))
        self._tasks[model.id] = task
        try:
            return await task
        finally:
            self._tasks.pop(model.id, None)

    async def _run(self, model: BigBroModel) -> Path:
        loop = asyncio.get_running_loop()
        completed = 0
        last_emit = 0.0

        self._emit(model.id, Progress("starting", 0, 0))
        patterns = patterns_for(model)
        total = await asyncio.to_thread(repo_total_bytes, model.repo, patterns)

        def on_progress(furthest: int) -> None:
            # Called from the Hub's worker threads — hop back to the loop to emit.
            nonlocal completed, last_emit
            # Monotonic: the counters can report out of order across threads, and a
            # bar that appears to go backwards reads as a stalled or corrupt download.
            completed = min(max(completed, furthest), total) if total else max(completed, furthest)
            now = time.monotonic()
            if now - last_emit < PROGRESS_INTERVAL:
                return
            last_emit = now
            loop.call_soon_threadsafe(
                self._emit, model.id, Progress("downloading", completed, total)
            )

        try:
            directory = await asyncio.to_thread(_snapshot, model.repo, patterns, on_progress)
        except Exception as exc:
            log.error("download failed for %s: %s", model.id, exc)
            self._emit(model.id, Progress("error", completed, total, done=True, error=str(exc)))
            raise

        self.record.record(model.id, directory)
        log.info("downloaded %s to %s", model.id, directory)
        # Finish at the total rather than wherever the counters landed: files already
        # cached are never counted, so a partly-cached repo would otherwise stop short.
        self._emit(model.id, Progress("complete", total or completed, total, done=True))
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
