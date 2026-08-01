"""The one thread every MLX call runs on.

MLX registers its streams per-thread. A model loaded on one thread and generated
from another raises

    RuntimeError: There is no Stream(gpu, 1) in current thread.

which is what inference did on every request: models were loaded on an
`asyncio.to_thread` worker and each generation ran on a thread of its own.

So there is exactly one MLX thread for the whole process — not one per engine.
mlx-lm, mlx-vlm and mlx-audio all sit on the same runtime, so a Kokoro load on a
different thread from a gpt-oss load would hit the same wall.

Serializing on one thread is also what the engines wanted anyway: MLX generation
is not safe to run concurrently, and both already held locks to prevent it. This
makes that structural rather than remembered.
"""

from __future__ import annotations

import asyncio
import logging
from concurrent.futures import Future, ThreadPoolExecutor
from typing import Any, Callable, Iterator, TypeVar

log = logging.getLogger("bigbro.mlx")

T = TypeVar("T")

_executor: ThreadPoolExecutor | None = None


def executor() -> ThreadPoolExecutor:
    """The single MLX worker, created on first use."""
    global _executor
    if _executor is None:
        _executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
    return _executor


async def run(fn: Callable[..., T], *args: Any) -> T:
    """Runs `fn` on the MLX thread and awaits the result.

    The event loop stays free while it runs; other requests queue behind it on the
    worker, which is the serialization MLX needs.
    """
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(executor(), fn, *args)


def submit(fn: Callable[..., T], *args: Any) -> "Future[T]":
    """Queues `fn` on the MLX thread without waiting for it."""
    return executor().submit(fn, *args)


def fire_and_forget(fn: Callable[..., Any], *args: Any) -> None:
    """Queues housekeeping that nothing waits on, logging any failure.

    Used for things like clearing MLX's buffer cache after a stop: it has to
    happen on the MLX thread, but no caller has a reason to block on it.
    """
    def guarded() -> None:
        try:
            fn(*args)
        except Exception as exc:  # pragma: no cover - depends on the MLX build
            log.warning("MLX housekeeping failed: %s", exc)

    submit(guarded)


def active_memory() -> int:
    """Bytes MLX currently has allocated, or 0 if it isn't loaded yet.

    Safe to call from any thread — it queries the allocator rather than touching a
    stream — but the engines read it on the MLX thread anyway, around a load, so
    the before/after pair cannot straddle another thread's work.
    """
    import sys

    module = sys.modules.get("mlx.core")
    reader = getattr(module, "get_active_memory", None) if module else None
    if reader is None:
        return 0
    try:
        return int(reader())
    except Exception:  # pragma: no cover - depends on the MLX build
        return 0


def clear_cache() -> None:
    """Returns MLX's cached buffers. Must run on the MLX thread."""
    import mlx.core as mx

    mx.clear_cache()


def drain_to_queue(make_iterator: Callable[[], Iterator[Any]], queue: Any, done: Any) -> None:
    """Runs a blocking generator on the MLX thread, pushing items onto `queue`.

    This is the streaming seam: generation has to happen on the MLX thread, but
    tokens have to reach the event loop as they are produced rather than at the
    end.
    """
    try:
        for item in make_iterator():
            queue.put(item)
    except Exception as exc:  # surfaced on the consuming side
        queue.put(exc)
    finally:
        queue.put(done)
