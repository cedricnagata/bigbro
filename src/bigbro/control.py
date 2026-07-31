"""The Unix socket the non-`serve` CLI verbs talk to.

`bigbro pair approve` has to reach the running daemon: only that process holds the
parked connection waiting on a decision. A Unix socket in the support directory keeps
that conversation off the network entirely — filesystem permissions are the whole
access control story, and nothing about pairing should ever be reachable from the
LAN the daemon is advertising on.

Reuses the peer protocol's framing so there is one codec rather than two that drift.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
from pathlib import Path
from typing import Any, Awaitable, Callable

from .config import control_socket_path
from .protocol.framing import read_frame, write_frame

log = logging.getLogger("bigbro.control")

Handler = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]

#: `sun_path` is 104 bytes on Darwin, 108 on Linux. Take the smaller.
_MAX_UNIX_PATH = 104

#: The one command that turns a connection into a long-lived event stream.
SUBSCRIBE = "subscribe"


class ControlServer:
    """Serves control commands to `bigbro` CLI invocations and attached UIs."""

    def __init__(
        self, handler: Handler, path: Path | None = None, bus: "EventBus | None" = None
    ) -> None:
        self._handler = handler
        self._path = path or control_socket_path()
        self._bus = bus
        self._server: asyncio.Server | None = None

    async def start(self) -> None:
        # macOS caps a Unix socket path at 104 bytes and reports the overflow as a
        # bare "AF_UNIX path too long", which says nothing about which path or why.
        # Only reachable via a deep BIGBRO_HOME, but that is exactly the case where
        # the cause is least obvious.
        encoded = str(self._path).encode()
        if len(encoded) >= _MAX_UNIX_PATH:
            raise OSError(
                f"Control socket path is {len(encoded)} bytes, over the {_MAX_UNIX_PATH}-byte "
                f"limit for Unix sockets: {self._path}. Set BIGBRO_HOME to a shorter directory."
            )

        # A socket left behind by a crashed daemon would make bind fail; nothing else
        # owns this path, so clearing it is safe.
        with contextlib.suppress(FileNotFoundError):
            self._path.unlink()

        self._server = await asyncio.start_unix_server(self._serve, path=str(self._path))
        # Owner-only: anyone who can write here can approve a device.
        os.chmod(self._path, 0o600)
        log.info("control socket at %s", self._path)

    async def stop(self) -> None:
        if self._server is not None:
            self._server.close()
            with contextlib.suppress(Exception):
                await self._server.wait_closed()
            self._server = None
        with contextlib.suppress(FileNotFoundError):
            self._path.unlink()

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            request = await read_frame(reader)
            if request is None:
                return

            if request.get("command") == SUBSCRIBE:
                await self._stream_events(reader, writer)
                return

            try:
                response = await self._handler(request)
            except Exception as exc:
                log.exception("control command failed")
                response = {"ok": False, "error": str(exc)}
            await write_frame(writer, response)
        except (ConnectionError, ValueError) as exc:
            log.warning("control connection failed: %s", exc)
        finally:
            with contextlib.suppress(Exception):
                writer.close()
                await writer.wait_closed()

    async def _stream_events(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        """Holds the connection open and pushes events until the client goes away.

        A dashboard cannot poll for a pairing request — the whole point is that it
        appears on its own. This is the only long-lived shape on the control socket;
        every other command is still one frame in, one frame out.
        """
        if self._bus is None:
            await write_frame(writer, {"ok": False, "error": "this daemon publishes no events"})
            return

        queue = self._bus.subscribe()
        await write_frame(writer, {"ok": True, "subscribed": True})
        log.debug("event subscriber attached (%d total)", self._bus.subscriber_count)

        # A subscriber that vanishes mid-stream is only detectable on write, which
        # may not happen for a while on a quiet daemon. Watching for EOF alongside
        # the queue lets the disconnect be noticed immediately.
        disconnect = asyncio.create_task(reader.read(1))
        try:
            while True:
                pending = asyncio.create_task(queue.get())
                done, _ = await asyncio.wait(
                    {pending, disconnect}, return_when=asyncio.FIRST_COMPLETED
                )
                if disconnect in done:
                    pending.cancel()
                    break
                await write_frame(writer, pending.result())
        except (ConnectionError, asyncio.CancelledError):
            pass
        finally:
            disconnect.cancel()
            self._bus.unsubscribe(queue)
            log.debug("event subscriber detached (%d left)", self._bus.subscriber_count)


class ControlClientError(Exception):
    pass


async def send_command(command: dict[str, Any], path: Path | None = None) -> dict[str, Any]:
    """Sends one command to a running daemon and returns its reply."""
    socket_path = path or control_socket_path()
    try:
        reader, writer = await asyncio.open_unix_connection(str(socket_path))
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        raise ControlClientError(
            f"No running daemon found at {socket_path}. Start one with: bigbro serve"
        ) from exc

    try:
        await write_frame(writer, command)
        response = await read_frame(reader)
    finally:
        with contextlib.suppress(Exception):
            writer.close()
            await writer.wait_closed()

    if response is None:
        raise ControlClientError("Daemon closed the connection without replying.")
    return response


@contextlib.asynccontextmanager
async def subscribe(path: Path | None = None):
    """Yields an async iterator of daemon events, on its own connection.

    Deliberately not multiplexed onto the command connection: a command is
    short-lived and may be issued while the UI is mid-render, and interleaving
    replies with pushed events on one socket would mean matching them up.
    """
    socket_path = path or control_socket_path()
    try:
        reader, writer = await asyncio.open_unix_connection(str(socket_path))
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        raise ControlClientError(
            f"No running daemon found at {socket_path}. Start one with: bigbro serve"
        ) from exc

    try:
        await write_frame(writer, {"command": SUBSCRIBE})
        ack = await read_frame(reader)
        if ack is None or not ack.get("ok"):
            raise ControlClientError(
                (ack or {}).get("error", "Daemon refused the event subscription.")
            )

        async def events():
            while True:
                event = await read_frame(reader)
                if event is None:
                    return
                yield event

        yield events()
    finally:
        with contextlib.suppress(Exception):
            writer.close()
            await writer.wait_closed()
