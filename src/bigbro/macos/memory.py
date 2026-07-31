"""What the daemon is costing in memory, and what the Mac has left.

Two numbers matter here and they answer different questions. The process's
resident size is what the Mac has actually given bigbro; MLX's active figure is
how much of that is model weights it is deliberately holding. When a 12 GB model
is resident those track each other closely, and when they diverge the gap is
cache and activations — which is exactly the thing worth seeing.

Bound with ctypes against libSystem, same as the Bonjour and power-assertion
bindings, so this adds no dependency. Every reader degrades to None off macOS
rather than raising: memory reporting is not worth failing a status call over.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
from dataclasses import dataclass, field

log = logging.getLogger("bigbro.memory")

_MACH_TASK_BASIC_INFO = 20
_KERN_SUCCESS = 0

#: kern.memorystatus_vm_pressure_level. macOS reports 1/2/4, not a scale.
PRESSURE_LEVELS = {1: "normal", 2: "warning", 4: "critical"}


class _MachTaskBasicInfo(ctypes.Structure):
    _fields_ = [
        ("virtual_size", ctypes.c_uint64),
        ("resident_size", ctypes.c_uint64),
        ("resident_size_max", ctypes.c_uint64),
        ("user_time", ctypes.c_int32 * 2),
        ("system_time", ctypes.c_int32 * 2),
        ("policy", ctypes.c_int32),
        ("suspend_count", ctypes.c_int32),
    ]


_lib = None


def _system():
    """Binds libSystem once, on first use. None off macOS."""
    global _lib
    if _lib is None:
        try:
            _lib = ctypes.CDLL(ctypes.util.find_library("System") or "/usr/lib/libSystem.dylib")
        except OSError:
            _lib = False
    return _lib or None


def process_memory() -> tuple[int | None, int | None]:
    """(resident bytes, peak resident bytes) for this process."""
    lib = _system()
    if lib is None:
        return None, None
    try:
        info = _MachTaskBasicInfo()
        count = ctypes.c_uint32(
            ctypes.sizeof(_MachTaskBasicInfo) // ctypes.sizeof(ctypes.c_uint32)
        )
        task = ctypes.c_uint.in_dll(lib, "mach_task_self_")
        if lib.task_info(task, _MACH_TASK_BASIC_INFO, ctypes.byref(info), ctypes.byref(count)) != _KERN_SUCCESS:
            return None, None
        return info.resident_size, info.resident_size_max
    except (OSError, ValueError, AttributeError):
        return None, None


def _sysctl(name: str, ctype):
    lib = _system()
    if lib is None:
        return None
    try:
        value = ctype()
        size = ctypes.c_size_t(ctypes.sizeof(ctype))
        if lib.sysctlbyname(name.encode(), ctypes.byref(value), ctypes.byref(size), None, 0) != 0:
            return None
        return value.value
    except (OSError, AttributeError):
        return None


def total_memory() -> int | None:
    """Bytes of RAM installed."""
    return _sysctl("hw.memsize", ctypes.c_uint64)


def pressure() -> str | None:
    """macOS's own memory pressure verdict.

    Reported rather than derived from free pages: on a Mac with compression and a
    dynamic file cache, "free" is close to meaningless, and this is the signal the
    system actually acts on.
    """
    level = _sysctl("kern.memorystatus_vm_pressure_level", ctypes.c_int32)
    return PRESSURE_LEVELS.get(level) if level is not None else None


def mlx_memory() -> dict[str, int]:
    """MLX's own accounting: weights and buffers it is holding.

    Empty until MLX has been imported and something loaded — importing it here
    just to read zeroes would pull the whole framework into a status call.
    """
    import sys

    module = sys.modules.get("mlx.core")
    if module is None:
        return {}

    result: dict[str, int] = {}
    for key, name in (
        ("active", "get_active_memory"),
        ("cache", "get_cache_memory"),
        ("peak", "get_peak_memory"),
    ):
        reader = getattr(module, name, None)
        if reader is None:
            continue
        try:
            result[key] = int(reader())
        except Exception:  # pragma: no cover - depends on the MLX build
            continue
    return result


def human(size: int | None) -> str:
    """Bytes as a short human figure. `None` becomes '?' rather than '0 B'."""
    if size is None:
        return "?"
    value = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.0f} {unit}" if unit in ("B", "KB") else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


@dataclass
class MemoryReport:
    resident: int | None = None
    peak: int | None = None
    total: int | None = None
    pressure: str | None = None
    mlx: dict[str, int] = field(default_factory=dict)
    #: Catalog id → bytes the model added when it loaded.
    models: dict[str, int] = field(default_factory=dict)

    @property
    def fraction_of_ram(self) -> float | None:
        if not self.resident or not self.total:
            return None
        return self.resident / self.total

    def to_wire(self) -> dict:
        return {
            "resident": self.resident,
            "peak": self.peak,
            "total": self.total,
            "pressure": self.pressure,
            "mlx": self.mlx,
            "models": self.models,
        }

    def summary(self) -> str:
        """One line, for the dashboard's status bar."""
        share = self.fraction_of_ram
        text = human(self.resident)
        if share is not None:
            text += f" of {human(self.total)} ({share * 100:.0f}%)"
        if self.pressure and self.pressure != "normal":
            text += f" · pressure {self.pressure}"
        return text


def report(models: dict[str, int] | None = None) -> MemoryReport:
    resident, peak = process_memory()
    return MemoryReport(
        resident=resident,
        peak=peak,
        total=total_memory(),
        pressure=pressure(),
        mlx=mlx_memory(),
        models=dict(models or {}),
    )
