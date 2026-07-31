"""Fan-out of daemon events to attached UIs.

The control socket was request/response: a CLI verb asked a question and got an
answer. A dashboard needs the opposite direction too — a pairing request has to
*appear* without anyone asking, and a download's progress has to move on its own.

Subscribers each get their own bounded queue. A slow or wedged UI drops its own
oldest events rather than applying backpressure to the daemon: nothing here is
worth stalling inference over, and the UI re-reads authoritative state via
`status` on reconnect anyway.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

log = logging.getLogger("bigbro.events")

#: Per-subscriber backlog. Deep enough to absorb a burst of download-progress
#: events, shallow enough that a detached UI cannot pin much memory.
QUEUE_SIZE = 256


class EventBus:
    def __init__(self) -> None:
        self._subscribers: set[asyncio.Queue] = set()

    @property
    def subscriber_count(self) -> int:
        return len(self._subscribers)

    def subscribe(self) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue(maxsize=QUEUE_SIZE)
        self._subscribers.add(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue) -> None:
        self._subscribers.discard(queue)

    def publish(self, event: str, **fields: Any) -> None:
        """Fans one event out to every subscriber. Never blocks, never raises.

        Called from ordinary daemon code paths — a pairing handler, a download
        callback — none of which should have to care whether a UI is attached or
        whether it is keeping up.
        """
        if not self._subscribers:
            return

        message = {"event": event, **fields}
        for queue in list(self._subscribers):
            while True:
                try:
                    queue.put_nowait(message)
                    break
                except asyncio.QueueFull:
                    # Drop this subscriber's oldest and retry, so a stalled UI
                    # loses history rather than the freshest state.
                    try:
                        queue.get_nowait()
                    except asyncio.QueueEmpty:
                        break


class LogEventHandler(logging.Handler):
    """Mirrors daemon log records onto the bus so an attached UI can show them.

    Matters for `bigbro ui`, which attaches to a daemon whose stdout it cannot
    see — without this the log pane would be empty for exactly the case that
    needs it most.
    """

    def __init__(self, bus: EventBus) -> None:
        super().__init__()
        self._bus = bus

    def emit(self, record: logging.LogRecord) -> None:
        # Never let the bus's own logging recurse back through here.
        if record.name.startswith("bigbro.events"):
            return
        try:
            self._bus.publish(
                "log",
                level=record.levelname,
                logger=record.name,
                message=record.getMessage(),
            )
        except Exception:  # pragma: no cover - a logging handler must not raise
            pass
