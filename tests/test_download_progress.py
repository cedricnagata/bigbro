"""Download progress reporting.

Written after the first live download reported "8 bytes total, 100% complete"
from its first byte. `snapshot_download` instantiates `tqdm_class` three times —
two byte counters and one that counts *files* — and the Hub decides for itself
whether those bars are disabled. A disabled tqdm short-circuits its own
`__init__`, so `unit` is never assigned and `update()` never advances `n`.

These tests drive the shim the way the Hub really does, including disabled.
"""

from __future__ import annotations

import asyncio

import pytest

from bigbro.inference.catalog import model as catalog_model
from bigbro.inference.downloader import ModelDownloader, _DevNull


class FakeHub:
    """Stands in for `snapshot_download`, driving tqdm_class as the Hub does."""

    def __init__(self, total_bytes=700_000_000, files=8, disabled=False, chunks=7):
        self.total_bytes = total_bytes
        self.files = files
        self.disabled = disabled
        self.chunks = chunks

    def __call__(self, repo_id, tqdm_class=None, allow_patterns=None, **kwargs):
        from pathlib import Path

        self.allow_patterns = allow_patterns

        # The Hub injects `disable` itself, based on log level and env.
        common = {"disable": True} if self.disabled else {}

        transfer = tqdm_class(total=0, initial=0, unit="B", unit_scale=True,
                              desc="Downloading bytes", **common)
        reconstruct = tqdm_class(total=0, initial=0, unit="B", unit_scale=True,
                                 desc="Reconstructing", **common)
        files_bar = tqdm_class(total=self.files, desc=f"Fetching {self.files} files", **common)

        step = self.total_bytes // self.chunks
        for _ in range(self.chunks):
            # Both byte bars report the same transfer from different ends.
            transfer.update(step)
            reconstruct.update(step)
        files_bar.update(self.files)      # one update per finished file
        return Path("/tmp/fake-snapshot")


@pytest.fixture
def downloader(tmp_path, monkeypatch):
    monkeypatch.setenv("BIGBRO_HOME", str(tmp_path))
    return ModelDownloader()


async def _download(downloader, monkeypatch, hub, total=700_000_000):
    """Runs a download against a fake Hub, returning every emitted Progress."""
    import huggingface_hub

    monkeypatch.setattr(huggingface_hub, "snapshot_download", hub, raising=False)
    monkeypatch.setattr(
        "bigbro.inference.downloader.repo_total_bytes", lambda *_a: total
    )
    # No throttle, so every update is observable.
    monkeypatch.setattr("bigbro.inference.downloader.PROGRESS_INTERVAL", 0.0)

    seen = []
    downloader.on_progress = lambda model_id, progress: seen.append(progress)
    await downloader.download(catalog_model("llama-3.2-1b"))
    await asyncio.sleep(0.05)  # let call_soon_threadsafe callbacks land
    return seen


async def test_total_comes_from_the_hub_api_not_the_bars(downloader, monkeypatch):
    """The file-count bar's total of 8 must never be mistaken for a byte total."""
    seen = await _download(downloader, monkeypatch, FakeHub())
    totals = {p.bytes_total for p in seen if p.bytes_total}
    assert totals == {700_000_000}


async def test_progress_climbs_rather_than_jumping_to_complete(downloader, monkeypatch):
    seen = await _download(downloader, monkeypatch, FakeHub())
    fractions = [round(p.fraction, 2) for p in seen if p.status == "downloading"]
    assert fractions == sorted(fractions), "progress went backwards"
    # Genuinely incremental, not 0% then 100%.
    assert len([f for f in fractions if 0.0 < f < 1.0]) >= 3


async def test_the_two_byte_bars_are_not_double_counted(downloader, monkeypatch):
    """Both report the same transfer from different ends; summing doubles it.

    Deliberately run with no known total, so the clamp that would otherwise hide
    an inflated tally is out of the way and the raw figure is what's asserted.
    """
    seen = await _download(downloader, monkeypatch, FakeHub(total_bytes=700_000_000), total=0)
    reported = max(p.bytes_completed for p in seen)
    assert reported == 700_000_000, f"expected the transfer size, got {reported:,}"


async def test_progress_never_exceeds_the_total(downloader, monkeypatch):
    seen = await _download(downloader, monkeypatch, FakeHub())
    assert all(p.bytes_completed <= p.bytes_total for p in seen if p.bytes_total)
    assert all(p.fraction <= 1.0 for p in seen)


async def test_the_file_count_bar_is_ignored(downloader, monkeypatch):
    """Its update(8) is files, not bytes, and would corrupt the tally."""
    hub = FakeHub(total_bytes=700_000_000, files=8, chunks=1)
    seen = await _download(downloader, monkeypatch, hub)
    during = [p.bytes_completed for p in seen if p.status == "downloading"]
    # One byte chunk was reported; the 8 from the files bar must not be added.
    assert during and max(during) == 700_000_000


async def test_it_works_when_the_hub_disables_the_bars(downloader, monkeypatch):
    """A disabled tqdm leaves `unit` unset and never advances `n`.

    Reading either off the bar raises AttributeError inside the Hub's worker
    threads, which surfaces as a failed download rather than a missing bar.
    """
    seen = await _download(downloader, monkeypatch, FakeHub(disabled=True))
    fractions = [p.fraction for p in seen if p.status == "downloading"]
    assert fractions, "no progress was reported with bars disabled"
    assert max(fractions) > 0.5


async def test_it_finishes_at_the_total_even_when_files_were_cached(downloader, monkeypatch):
    """Cached files are never counted, so the tally alone would stop short."""
    hub = FakeHub(total_bytes=700_000_000, chunks=1)  # only part reported
    monkeypatch.setattr(
        "bigbro.inference.downloader.repo_total_bytes", lambda *_a: 2_000_000_000
    )
    seen = await _download(downloader, monkeypatch, hub, total=2_000_000_000)
    final = seen[-1]
    assert final.done and final.status == "complete"
    assert final.bytes_completed == final.bytes_total == 2_000_000_000
    assert final.fraction == 1.0


async def test_a_failed_download_reports_the_error(downloader, monkeypatch):
    import huggingface_hub

    def boom(**_kwargs):
        raise OSError("connection reset")

    monkeypatch.setattr(huggingface_hub, "snapshot_download", boom, raising=False)
    monkeypatch.setattr("bigbro.inference.downloader.repo_total_bytes", lambda *_a: 100)

    seen = []
    downloader.on_progress = lambda model_id, progress: seen.append(progress)
    with pytest.raises(OSError):
        await downloader.download(catalog_model("llama-3.2-1b"))

    assert seen[-1].done and seen[-1].error is not None
    assert "connection reset" in seen[-1].error


def test_devnull_satisfies_what_tqdm_asks_of_a_stream():
    stream = _DevNull()
    assert stream.write("anything") == 0
    stream.flush()
    assert stream.isatty() is False


def test_repo_total_bytes_sums_the_file_metadata(monkeypatch):
    from bigbro.inference import downloader as module

    class Sibling:
        def __init__(self, size): self.size = size

    class FakeApi:
        def model_info(self, repo, files_metadata=False):
            assert files_metadata
            return type("Info", (), {"siblings": [Sibling(100), Sibling(250), Sibling(None)]})()

    monkeypatch.setattr("huggingface_hub.HfApi", FakeApi)
    assert module.repo_total_bytes("some/repo") == 350


def test_repo_total_bytes_degrades_to_zero_when_the_hub_is_unreachable(monkeypatch):
    """An unknown total is better than a wrong one — the UI shows bytes, not a %."""
    from bigbro.inference import downloader as module

    class FakeApi:
        def model_info(self, *a, **k):
            raise OSError("offline")

    monkeypatch.setattr("huggingface_hub.HfApi", FakeApi)
    assert module.repo_total_bytes("some/repo") == 0


# MARK: - What actually gets fetched


async def test_language_models_use_mlx_lm_patterns(downloader, monkeypatch):
    """Fetching the whole repo costs bandwidth on files MLX never opens."""
    from bigbro.inference.downloader import LANGUAGE_PATTERNS

    hub = FakeHub()
    await _download(downloader, monkeypatch, hub)
    assert hub.allow_patterns == list(LANGUAGE_PATTERNS)


async def test_vision_models_use_mlx_vlm_patterns(downloader, monkeypatch):
    """The two differ — `model*.safetensors` vs `*.safetensors` above all."""
    from bigbro.inference.downloader import VISION_PATTERNS

    import huggingface_hub
    hub = FakeHub()
    monkeypatch.setattr(huggingface_hub, "snapshot_download", hub, raising=False)
    monkeypatch.setattr("bigbro.inference.downloader.repo_total_bytes", lambda *a: 100)
    monkeypatch.setattr("bigbro.inference.downloader.PROGRESS_INTERVAL", 0.0)

    await downloader.download(catalog_model("qwen2.5-vl-3b"))
    assert hub.allow_patterns == list(VISION_PATTERNS)


def test_a_vision_repo_would_lose_its_weights_under_language_patterns():
    """`model*.safetensors` misses the shard names vision repos actually use."""
    from fnmatch import fnmatch
    from bigbro.inference.downloader import LANGUAGE_PATTERNS, VISION_PATTERNS

    vision_shard = "vision_tower.safetensors"
    assert not any(fnmatch(vision_shard, p) for p in LANGUAGE_PATTERNS)
    assert any(fnmatch(vision_shard, p) for p in VISION_PATTERNS)


def test_sizing_counts_only_the_files_that_will_be_fetched(monkeypatch):
    """A total counting skipped files is a bar that can never reach 100%."""
    from bigbro.inference import downloader as module

    class Sibling:
        def __init__(self, name, size): self.rfilename, self.size = name, size

    class FakeApi:
        def model_info(self, repo, files_metadata=False):
            return type("Info", (), {"siblings": [
                Sibling("model-00001-of-00002.safetensors", 5_000_000_000),
                Sibling("config.json", 1_000),
                Sibling("pytorch_model.bin", 9_000_000_000),   # original weights
                Sibling("model.gguf", 4_000_000_000),          # a conversion
                Sibling("preview.png", 500_000),
            ]})()

    monkeypatch.setattr("huggingface_hub.HfApi", FakeApi)
    counted = module.repo_total_bytes("some/repo", list(module.LANGUAGE_PATTERNS))
    assert counted == 5_000_001_000, "the .bin, .gguf and .png must not be counted"


def test_sizing_without_patterns_counts_everything(monkeypatch):
    from bigbro.inference import downloader as module

    class Sibling:
        def __init__(self, name, size): self.rfilename, self.size = name, size

    class FakeApi:
        def model_info(self, repo, files_metadata=False):
            return type("Info", (), {"siblings": [Sibling("a.bin", 10), Sibling("b.json", 5)]})()

    monkeypatch.setattr("huggingface_hub.HfApi", FakeApi)
    assert module.repo_total_bytes("some/repo") == 15
