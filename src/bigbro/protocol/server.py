"""The TCP server iOS devices connect to. Port of Server/PeerServer.swift.

Connections live in one of two maps: `_pending` before a `hello` has been approved,
`_peers` after. That split is what lets an unapproved device be replied to (with a
denial) without ever being addressable by device id.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
import uuid
from typing import Any, Protocol

from .framing import FrameDecoder, encode

log = logging.getLogger("bigbro.server")


class PeerServerDelegate(Protocol):
    """What PeerServer calls back into. Implemented by `router.AppRouter`."""

    async def on_message(self, message: dict[str, Any], connection_id: str) -> None: ...
    async def on_peer_disconnected(self, device_id: str) -> None: ...


class _Connection:
    __slots__ = ("id", "reader", "writer", "decoder")

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.id = uuid.uuid4().hex
        self.reader = reader
        self.writer = writer
        self.decoder = FrameDecoder()


class PeerServer:
    """Framed-TCP server for paired iOS devices."""

    def __init__(self) -> None:
        self._server: asyncio.Server | None = None
        self._pending: dict[str, _Connection] = {}          # before hello
        self._peers: dict[str, _Connection] = {}            # after hello: deviceId → conn
        self._device_ids: dict[str, str] = {}               # connectionId → deviceId
        self._last_heard: dict[str, float] = {}             # deviceId → monotonic timestamp
        self._read_tasks: set[asyncio.Task] = set()
        self.delegate: PeerServerDelegate | None = None

    # MARK: - Lifecycle

    async def start(self, port: int, host: str | None = None) -> None:
        """Binds the listener. `host=None` means every interface, both address families.

        Dual-stack matters here rather than being a nicety: mDNSResponder advertises
        this Mac's `.local` name with its IPv6 addresses alongside its IPv4 one, and
        `NetService` resolution on iOS may hand the client either. Binding
        `0.0.0.0` would leave a device that resolved to IPv6 discovering the service
        and then failing to connect to it — which is what `NWListener` did for free
        in the Swift original.
        """
        self._server = await asyncio.start_server(self._accept, host, port)
        bound = ", ".join(
            sorted({f"{s.getsockname()[0]}:{s.getsockname()[1]}" for s in self._server.sockets or []})
        )
        log.info("listening on %s", bound or f"{host}:{port}")

    async def shutdown(self) -> None:
        """Sends `bye` to every peer, then stops. Use for graceful shutdown."""
        log.info("shutting down: saying bye to %d peer(s)", len(self._peers))
        for device_id in list(self._peers):
            await self.send({"type": "bye"}, to=device_id)
        await self.stop()

    async def stop(self) -> None:
        if self._server is not None:
            self._server.close()
            with contextlib.suppress(Exception):
                await self._server.wait_closed()
            self._server = None

        for task in list(self._read_tasks):
            task.cancel()
        self._read_tasks.clear()

        for conn in list(self._peers.values()) + list(self._pending.values()):
            self._close(conn)

        self._peers.clear()
        self._pending.clear()
        self._device_ids.clear()
        self._last_heard.clear()

    # MARK: - Peer registry

    def register(self, connection_id: str, device_id: str) -> None:
        """Promotes an approved connection out of `_pending` into `_peers`."""
        conn = self._pending.pop(connection_id, None)
        if conn is None:
            log.warning("register: no pending connection %s", connection_id)
            return
        self._peers[device_id] = conn
        self._device_ids[connection_id] = device_id
        self._last_heard[device_id] = time.monotonic()
        log.info("connection %s registered as device %s", connection_id[:8], device_id[:8])

    def device_id(self, connection_id: str) -> str | None:
        return self._device_ids.get(connection_id)

    def is_connected(self, device_id: str) -> bool:
        """Whether a peer is still attached.

        Lets long-running sends — streamed audio above all — stop early instead of
        logging one failure per frame into a dead connection.
        """
        return device_id in self._peers

    def last_heard(self, device_id: str) -> float | None:
        return self._last_heard.get(device_id)

    @property
    def connected_device_ids(self) -> list[str]:
        return list(self._peers)

    # MARK: - Sending

    async def send(self, message: dict[str, Any], to: str) -> None:
        conn = self._peers.get(to)
        if conn is None:
            log.warning("send: no peer for device %s", to[:8])
            return
        # Audio streams at several frames a second; logging every one drowns everything else.
        if message.get("type") != "audioChunk":
            log.debug("→ %s: %s", to[:8], message.get("type", "?"))
        await self._write(conn, message)

    async def send_to_pending(self, message: dict[str, Any], connection_id: str) -> None:
        conn = self._pending.get(connection_id)
        if conn is None:
            log.warning("send_to_pending: no pending connection %s", connection_id)
            return
        log.debug("→ pending %s: %s", connection_id[:8], message.get("type", "?"))
        await self._write(conn, message)

    async def broadcast(self, message: dict[str, Any]) -> None:
        for device_id in list(self._peers):
            await self.send(message, to=device_id)

    async def disconnect(self, device_id: str) -> None:
        """Sends `bye` then closes. The device stays paired and may reconnect."""
        log.info("disconnecting device %s", device_id[:8])
        await self.send({"type": "bye"}, to=device_id)
        conn = self._peers.pop(device_id, None)
        self._last_heard.pop(device_id, None)
        if conn is not None:
            self._close(conn)
        # `_device_ids` is left intact so the read loop still recognizes whose
        # connection just closed and reports the disconnect exactly once.

    def disconnect_pending(self, connection_id: str) -> None:
        conn = self._pending.pop(connection_id, None)
        if conn is not None:
            log.info("disconnecting pending %s", connection_id[:8])
            self._close(conn)

    # MARK: - Internals

    async def _write(self, conn: _Connection, message: dict[str, Any]) -> None:
        try:
            conn.writer.write(encode(message))
            await conn.writer.drain()
        except (ConnectionError, RuntimeError) as exc:
            log.warning("send failed on %s: %s", conn.id[:8], exc)

    def _close(self, conn: _Connection) -> None:
        with contextlib.suppress(Exception):
            conn.writer.close()

    async def _accept(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        conn = _Connection(reader, writer)
        self._pending[conn.id] = conn
        log.info("accepted connection %s", conn.id[:8])

        task = asyncio.current_task()
        if task is not None:
            self._read_tasks.add(task)
        try:
            await self._read_loop(conn)
        finally:
            if task is not None:
                self._read_tasks.discard(task)
            await self._teardown(conn)

    async def _read_loop(self, conn: _Connection) -> None:
        while True:
            try:
                chunk = await conn.reader.read(65536)
            except (ConnectionError, asyncio.IncompleteReadError):
                break
            if not chunk:
                break  # clean EOF — this is how a dropped peer surfaces

            try:
                messages = conn.decoder.feed(chunk)
            except ValueError as exc:
                log.error("closing %s: %s", conn.id[:8], exc)
                break

            for message in messages:
                device_id = self._device_ids.get(conn.id)
                if device_id is not None:
                    self._last_heard[device_id] = time.monotonic()
                    # Answered here rather than in the router so a keepalive is never
                    # queued behind an in-flight generation.
                    if message.get("type") == "ping":
                        await self.send({"type": "pong"}, to=device_id)
                        continue

                log.debug("← %s: %s", conn.id[:8], message.get("type", "?"))
                if self.delegate is not None:
                    await self.delegate.on_message(message, conn.id)

    async def _teardown(self, conn: _Connection) -> None:
        device_id = self._device_ids.pop(conn.id, None)
        self._pending.pop(conn.id, None)
        self._close(conn)

        if device_id is None:
            log.info("pending connection %s closed before hello", conn.id[:8])
            return

        self._peers.pop(device_id, None)
        self._last_heard.pop(device_id, None)
        log.info("device %s disconnected", device_id[:8])
        if self.delegate is not None:
            await self.delegate.on_peer_disconnected(device_id)
