"""A real ControlServer in front of a StubDaemon, for the Swift client's tests.

Swift can stub a socket perfectly well on its own, but a stub written twice in two
languages cannot catch the mistakes that matter most here. `status` spells it
`keepAwake` and `settings.get` spells it `keep_awake`; whoever writes the Swift
stub writes it from the same reading of the daemon that produced the Swift
decoder, so a misreading agrees with itself and both sides go green. Putting the
*real* framing, the real `ControlServer` and the real reply shapes behind a socket
is what makes that class of bug fail.

Usage:

    python tests/serve_stub.py /tmp/bigbro-swift-test/c.sock

Prints `ready` on its own line once the socket is accepting connections, then
serves until killed. Keep the path short — `sun_path` is 104 bytes on Darwin, and
`ControlServer.start` refuses anything longer.

Events are driven, not timed: send `{"command": "test.publish", "event": ..., …}`
and it goes out on the subscribe stream. A test that waits for a pairing prompt
should decide when the prompt happens.
"""

from __future__ import annotations

import asyncio
import contextlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stub_daemon import StubDaemon  # noqa: E402

from bigbro.control import ControlServer  # noqa: E402


async def main(socket_path: Path) -> None:
    stub = StubDaemon()

    async def handle(request: dict) -> dict:
        # Not part of the daemon's command set — this is the test's handle on the
        # event stream, so a Swift test can say when a pairing request arrives
        # rather than sleeping and hoping.
        if request.get("command") == "test.publish":
            event = request.get("event")
            if not event:
                return {"ok": False, "error": "test.publish needs an 'event'"}
            stub.bus.publish(event, **(request.get("fields") or {}))
            return {"ok": True, "published": event}
        return await stub.handle(request)

    socket_path.parent.mkdir(parents=True, exist_ok=True)
    server = ControlServer(handle, socket_path, bus=stub.bus)
    await server.start()

    # The Swift side blocks on this line rather than polling for the socket file,
    # which would race: the path exists between bind and listen.
    print("ready", flush=True)

    try:
        await asyncio.Event().wait()
    finally:
        await server.stop()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <socket-path>")
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(main(Path(sys.argv[1])))
