"""Memory reporting.

The readings themselves come from the kernel, so what is worth testing is the
shape around them: that a missing reading degrades to "?" instead of a crash or a
misleading zero, that the arithmetic is right, and that per-model attribution
only claims models actually resident.
"""

from __future__ import annotations

import sys

import pytest

from bigbro.macos import memory as mem

darwin_only = pytest.mark.skipif(sys.platform != "darwin", reason="macOS bindings")


# MARK: - Live readings


@darwin_only
def test_process_memory_is_plausible():
    resident, peak = mem.process_memory()
    assert resident is not None and peak is not None
    # A Python process with the test suite loaded is megabytes, not bytes or terabytes.
    assert 1_000_000 < resident < 20_000_000_000
    assert peak >= resident


@darwin_only
def test_total_memory_matches_a_real_mac():
    total = mem.total_memory()
    assert total is not None
    assert 1_000_000_000 < total < 10_000_000_000_000


@darwin_only
def test_pressure_is_one_of_the_known_levels():
    assert mem.pressure() in (None, "normal", "warning", "critical")


def test_mlx_memory_is_empty_when_mlx_is_not_loaded(monkeypatch):
    """Reading memory must not drag the whole MLX framework into a status call."""
    monkeypatch.delitem(sys.modules, "mlx.core", raising=False)
    assert mem.mlx_memory() == {}


def test_mlx_memory_reads_what_the_module_exposes(monkeypatch):
    class FakeMLX:
        get_active_memory = staticmethod(lambda: 12_000_000_000)
        get_cache_memory = staticmethod(lambda: 500_000_000)
        get_peak_memory = staticmethod(lambda: 13_000_000_000)

    monkeypatch.setitem(sys.modules, "mlx.core", FakeMLX)
    assert mem.mlx_memory() == {
        "active": 12_000_000_000, "cache": 500_000_000, "peak": 13_000_000_000,
    }


def test_a_reader_that_raises_is_skipped_not_fatal(monkeypatch):
    class BrokenMLX:
        @staticmethod
        def get_active_memory():
            raise RuntimeError("metal is unhappy")
        get_cache_memory = staticmethod(lambda: 7)

    monkeypatch.setitem(sys.modules, "mlx.core", BrokenMLX)
    assert mem.mlx_memory() == {"cache": 7}


# MARK: - Formatting


@pytest.mark.parametrize("size,expected", [
    (None, "?"),
    (0, "0 B"),
    (512, "512 B"),
    (2048, "2 KB"),
    (5 * 1024**2, "5.0 MB"),
    (12 * 1024**3, "12.0 GB"),
])
def test_human(size, expected):
    assert mem.human(size) == expected


def test_unknown_is_a_question_mark_not_zero():
    """"0 B" would read as "using nothing", which is a different claim."""
    assert mem.human(None) == "?"


# MARK: - The report


def test_fraction_of_ram():
    report = mem.MemoryReport(resident=8 * 1024**3, total=32 * 1024**3)
    assert report.fraction_of_ram == pytest.approx(0.25)


@pytest.mark.parametrize("resident,total", [(None, 1), (1, None), (0, 100)])
def test_fraction_is_none_when_it_cannot_be_computed(resident, total):
    assert mem.MemoryReport(resident=resident, total=total).fraction_of_ram is None


def test_summary_includes_the_share_of_ram():
    summary = mem.MemoryReport(resident=8 * 1024**3, total=32 * 1024**3).summary()
    assert "8.0 GB" in summary and "32.0 GB" in summary and "25%" in summary


def test_summary_flags_pressure_only_when_it_is_not_normal():
    normal = mem.MemoryReport(resident=1024, total=2048, pressure="normal")
    assert "pressure" not in normal.summary()

    warned = mem.MemoryReport(resident=1024, total=2048, pressure="warning")
    assert "pressure warning" in warned.summary()


def test_summary_survives_a_reading_it_could_not_take():
    assert mem.MemoryReport().summary() == "?"


def test_report_round_trips_to_the_wire():
    wire = mem.MemoryReport(
        resident=100, peak=200, footprint=150, total=300, pressure="normal",
        mlx={"active": 50}, models={"qwen3-4b": 40},
    ).to_wire()
    assert wire == {
        "resident": 100, "peak": 200, "footprint": 150, "total": 300,
        "pressure": "normal", "mlx": {"active": 50}, "models": {"qwen3-4b": 40},
        "headline": 50, "weights": 50,
    }


# MARK: - Per-model attribution


async def test_memory_is_attributed_only_to_running_models(tmp_path, monkeypatch):
    """A stopped model is no longer being held, so it must stop being counted."""
    monkeypatch.setenv("BIGBRO_HOME", str(tmp_path))
    from bigbro.inference.engine import MLXEngine

    engine = MLXEngine()
    engine._loaded = {"qwen3-4b": object(), "gpt-oss-20b": object()}
    engine._memory = {"qwen3-4b": 2_400_000_000, "gpt-oss-20b": 12_000_000_000}
    assert set(engine.memory_by_model) == {"qwen3-4b", "gpt-oss-20b"}

    engine.stop("gpt-oss-20b")
    assert set(engine.memory_by_model) == {"qwen3-4b"}


async def test_a_model_that_never_reported_a_figure_is_simply_absent(tmp_path, monkeypatch):
    monkeypatch.setenv("BIGBRO_HOME", str(tmp_path))
    from bigbro.inference.engine import MLXEngine

    engine = MLXEngine()
    engine._loaded = {"qwen3-4b": object()}
    assert engine.memory_by_model == {}


def test_active_memory_reader_is_zero_without_mlx(monkeypatch):
    from bigbro.inference.engine import _mlx_active_memory

    monkeypatch.delitem(sys.modules, "mlx.core", raising=False)
    assert _mlx_active_memory() == 0


# MARK: - Which number leads
#
# The process figures are not trustworthy for "what is this model costing".
# Measured across three loads of the same 12 GB model, resident size read 1.8 GB
# once and 11.8 GB on the others, and after unloading it still reported 10.6 GB
# while MLX held 400 KB. MLX said 11.2 GB every time.


def test_weights_lead_when_a_model_is_loaded():
    report = mem.MemoryReport(
        resident=1_800_000_000, footprint=1_700_000_000, total=36_000_000_000,
        mlx={"active": 11_200_000_000},
    )
    assert report.headline == 11_200_000_000
    assert "10.4 GB" in report.summary()


def test_the_process_figure_leads_when_nothing_is_loaded():
    """MLX reports zero with nothing loaded, which would read as "using nothing"."""
    report = mem.MemoryReport(resident=40_000_000, footprint=35_000_000, total=36_000_000_000)
    assert report.headline == 35_000_000


def test_a_stale_process_figure_does_not_inflate_the_headline():
    """After unload the allocator has not returned the pages; MLX has."""
    report = mem.MemoryReport(
        resident=10_600_000_000, footprint=10_600_000_000, total=36_000_000_000,
        mlx={"active": 400_000},
    )
    assert report.headline == 400_000


def test_share_of_ram_is_computed_from_the_headline():
    report = mem.MemoryReport(
        resident=1_000, footprint=1_000, total=36_000_000_000,
        mlx={"active": 18_000_000_000},
    )
    assert report.fraction_of_ram == pytest.approx(0.5)
