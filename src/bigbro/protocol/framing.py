"""The wire codec: a 4-byte big-endian length prefix followed by a UTF-8 JSON object.

Unchanged from BigBro's Ollama-proxy days and unchanged by the move off Swift —
existing BigBroKit clients talk to this daemon without a rebuild. The control
socket (`bigbro pair`, `bigbro models`) reuses the same framing so there is one
implementation of it rather than two that can drift.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

LENGTH_PREFIX_BYTES = 4

# A frame this large is a desync or a hostile peer, not a real message. The largest
# legitimate frame is a `transcribeRequest` carrying base64 audio, which the router
# separately caps at 10 MB decoded (~13.4 MB encoded).
MAX_FRAME_BYTES = 32 * 1024 * 1024


def encode(message: dict[str, Any]) -> bytes:
    """Serializes one message to a length-prefixed frame."""
    body = json.dumps(message, separators=(",", ":")).encode()
    return len(body).to_bytes(LENGTH_PREFIX_BYTES, "big") + body


class FrameDecoder:
    """Reassembles frames from arbitrarily-chunked reads.

    TCP gives no message boundaries, so a single read can carry half a frame, three
    frames, or a frame split across two reads. Feed it whatever arrives and take
    whatever became complete.
    """

    def __init__(self, max_frame_bytes: int = MAX_FRAME_BYTES) -> None:
        self._buffer = bytearray()
        self._max_frame_bytes = max_frame_bytes

    def feed(self, chunk: bytes) -> list[dict[str, Any]]:
        """Appends `chunk` and returns every message that is now complete.

        Frames that are not valid JSON are skipped rather than raising — one
        malformed message should not tear down a connection that is otherwise fine.
        """
        self._buffer += chunk
        messages: list[dict[str, Any]] = []

        while len(self._buffer) >= LENGTH_PREFIX_BYTES:
            length = int.from_bytes(self._buffer[:LENGTH_PREFIX_BYTES], "big")
            if length > self._max_frame_bytes:
                raise ValueError(f"frame of {length} bytes exceeds the {self._max_frame_bytes} byte limit")
            if len(self._buffer) < LENGTH_PREFIX_BYTES + length:
                break

            body = bytes(self._buffer[LENGTH_PREFIX_BYTES:LENGTH_PREFIX_BYTES + length])
            del self._buffer[:LENGTH_PREFIX_BYTES + length]
            try:
                decoded = json.loads(body)
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if isinstance(decoded, dict):
                messages.append(decoded)

        return messages


async def read_frame(reader: asyncio.StreamReader) -> dict[str, Any] | None:
    """Reads exactly one frame, or None at clean end-of-stream.

    Used by the control socket, which is strictly request/response and so has no
    need for the incremental decoder above.
    """
    try:
        header = await reader.readexactly(LENGTH_PREFIX_BYTES)
    except asyncio.IncompleteReadError:
        return None

    length = int.from_bytes(header, "big")
    if length > MAX_FRAME_BYTES:
        raise ValueError(f"frame of {length} bytes exceeds the {MAX_FRAME_BYTES} byte limit")
    try:
        body = await reader.readexactly(length)
    except asyncio.IncompleteReadError:
        return None

    decoded = json.loads(body)
    return decoded if isinstance(decoded, dict) else None


async def write_frame(writer: asyncio.StreamWriter, message: dict[str, Any]) -> None:
    writer.write(encode(message))
    await writer.drain()
