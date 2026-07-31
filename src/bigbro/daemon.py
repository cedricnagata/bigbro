"""Wires everything together and owns the process lifecycle.

Startup order matters: the TCP listener comes up before Bonjour advertises it, so a
device that reacts instantly to the advertisement always finds something listening.
Shutdown unwinds in reverse, and says `bye` to every peer before dropping the
listener so clients see a clean disconnect rather than a dead socket.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import signal
import sys
from typing import Any

from .config import DEFAULT_PORT
from .control import ControlServer
from .inference import catalog
from .inference.downloader import ModelDownloader, Progress
from .inference.engine import MLXEngine
from .macos.bonjour import BonjourAdvertiser, computer_name
from .macos.power import PowerAssertion
from .protocol.pairing import PairingManager
from .protocol.server import PeerServer
from .router import AppRouter
from .speech import ModelKind, SpeechEngine

log = logging.getLogger("bigbro.daemon")


class Daemon:
    def __init__(self, port: int = DEFAULT_PORT, keep_awake: bool = True) -> None:
        self.port = port
        self.keep_awake = keep_awake

        self.downloader = ModelDownloader()
        self.engine = MLXEngine(self.downloader)
        self.speech = SpeechEngine(self.downloader.record)
        self.pairing = PairingManager()
        self.server = PeerServer()
        self.advertiser = BonjourAdvertiser()
        self.power = PowerAssertion()
        self.router = AppRouter(self.server, self.pairing, self.engine, self.speech)
        self.control = ControlServer(self.handle_control)

        self.server.delegate = self.router
        self.pairing.is_model_satisfied = self.engine.is_required_model_satisfied
        self.downloader.on_progress = self._on_download_progress

        self._stopping = asyncio.Event()
        self._loop: asyncio.AbstractEventLoop | None = None

    # MARK: - Lifecycle

    async def run(self) -> None:
        self._loop = asyncio.get_running_loop()
        self._install_signal_handlers()

        await self.server.start(self.port)
        self.advertiser.start(self.port)
        await self.control.start()

        if self.keep_awake:
            self.power.acquire("bigbro is serving nearby devices")
        else:
            log.info("--no-keep-awake: the Mac may sleep while bigbro is running")

        log.info(
            "bigbro is serving as '%s' on port %d — %d paired device(s)",
            computer_name(), self.port, len(self.pairing.approved_device_ids),
        )

        try:
            await self._stopping.wait()
        finally:
            await self.shutdown()

    def stop(self) -> None:
        self._stopping.set()

    async def shutdown(self) -> None:
        log.info("shutting down")
        self.advertiser.stop()
        await self.control.stop()
        await self.server.shutdown()
        self.power.release()

    def _install_signal_handlers(self) -> None:
        assert self._loop is not None
        for sig in (signal.SIGINT, signal.SIGTERM):
            with contextlib.suppress(NotImplementedError):
                self._loop.add_signal_handler(sig, self.stop)

    # MARK: - Download progress

    def _on_download_progress(self, model_id: str, progress: Progress) -> None:
        """Broadcasts progress to every connected peer.

        Sent for every download — peers decide which to surface based on what they
        care about.
        """
        message: dict[str, Any] = {
            "type": "modelDownloadComplete" if progress.done else "modelDownloadProgress",
            "model": model_id,
            "status": progress.status,
            "completed": progress.bytes_completed,
            "total": progress.bytes_total,
        }
        if progress.done:
            message["success"] = progress.error is None
            if progress.error:
                message["error"] = progress.error

        if self._loop is not None:
            asyncio.ensure_future(self.server.broadcast(message))

    # MARK: - Control commands

    async def handle_control(self, request: dict[str, Any]) -> dict[str, Any]:
        command = request.get("command")
        handlers = {
            "status": self._control_status,
            "pair.list": self._control_pair_list,
            "pair.approve": self._control_pair_decide,
            "pair.deny": self._control_pair_decide,
            "pair.remove": self._control_pair_remove,
            "pair.remove-all": self._control_pair_remove_all,
            "pair.disconnect": self._control_pair_disconnect,
            "models.list": self._control_models_list,
            "models.download": self._control_models_download,
            "models.run": self._control_models_run,
            "models.stop": self._control_models_stop,
            "models.remove": self._control_models_remove,
        }
        handler = handlers.get(command)
        if handler is None:
            return {"ok": False, "error": f"unknown command '{command}'"}
        return await handler(request)

    async def _control_status(self, _request: dict[str, Any]) -> dict[str, Any]:
        running = [m.id for m in catalog.ALL_MODELS if self.engine.is_running(m.id)]
        downloaded = [m.id for m in catalog.ALL_MODELS if self.engine.is_downloaded(m.id)]
        return {
            "ok": True,
            "name": computer_name(),
            "port": self.port,
            "keepAwake": self.power.held,
            "paired": len(self.pairing.approved_device_ids),
            "connected": self.server.connected_device_ids,
            "pending": [r.to_wire() for r in self.pairing.pending_requests],
            "running": running,
            "downloaded": downloaded,
            "speech": {
                kind.value: self.speech.state_description(kind) for kind in ModelKind
            },
        }

    async def _control_pair_list(self, _request: dict[str, Any]) -> dict[str, Any]:
        return {
            "ok": True,
            "pending": [r.to_wire() for r in self.pairing.pending_requests],
            "devices": [
                self.pairing.describe(device_id)
                for device_id in self.pairing.approved_device_ids
            ],
        }

    async def _control_pair_decide(self, request: dict[str, Any]) -> dict[str, Any]:
        device_id = str(request.get("deviceId") or "")
        approved = request.get("command") == "pair.approve"
        if not device_id:
            return {"ok": False, "error": "no device id given"}

        resolved = self.pairing.resolve_pending(device_id, approved)
        if resolved is None:
            return {
                "ok": False,
                "error": f"no pending request matching '{device_id}' (an ambiguous prefix matches nothing)",
            }
        return {
            "ok": True,
            "deviceId": resolved.device_id,
            "deviceName": resolved.device_name,
            "approved": approved,
        }

    async def _control_pair_remove(self, request: dict[str, Any]) -> dict[str, Any]:
        prefix = str(request.get("deviceId") or "")
        device_id = self.pairing.resolve_device_id(prefix)
        if device_id is None:
            return {"ok": False, "error": f"no paired device matching '{prefix}'"}

        name = self.pairing.display_name(device_id)
        if self.server.is_connected(device_id):
            await self.server.disconnect(device_id)
        self.pairing.remove(device_id)
        return {"ok": True, "deviceId": device_id, "name": name}

    async def _control_pair_remove_all(self, _request: dict[str, Any]) -> dict[str, Any]:
        for device_id in list(self.server.connected_device_ids):
            await self.server.disconnect(device_id)
        count = self.pairing.remove_all()
        return {"ok": True, "removed": count}

    async def _control_pair_disconnect(self, request: dict[str, Any]) -> dict[str, Any]:
        prefix = str(request.get("deviceId") or "")
        device_id = self.pairing.resolve_device_id(prefix)
        if device_id is None:
            return {"ok": False, "error": f"no paired device matching '{prefix}'"}
        await self.server.disconnect(device_id)
        self.pairing.mark_disconnected(device_id)
        return {"ok": True, "deviceId": device_id}

    async def _control_models_list(self, _request: dict[str, Any]) -> dict[str, Any]:
        return {
            "ok": True,
            "models": [
                {
                    "id": model.id,
                    "name": model.display_name,
                    "family": model.family.value,
                    "state": self.engine.state_description(model.id),
                    "sizeGB": model.approximate_gb,
                    "tools": model.supports_tools,
                    "images": model.supports_images,
                    "reasoning": model.reasoning.value,
                }
                for model in catalog.ALL_MODELS
            ],
            "speech": [
                {"id": kind.value, "name": kind.display_name, "state": self.speech.state_description(kind)}
                for kind in ModelKind
            ],
        }

    def _lookup(self, request: dict[str, Any]):
        name = str(request.get("model") or "")
        return name, catalog.resolve(name)

    async def _control_models_download(self, request: dict[str, Any]) -> dict[str, Any]:
        name, model = self._lookup(request)
        if model is None:
            return {"ok": False, "error": f"'{name}' is not a model BigBro knows about."}
        asyncio.ensure_future(self.router._download_quietly(model))  # noqa: SLF001
        return {"ok": True, "model": model.id, "started": True}

    async def _control_models_run(self, request: dict[str, Any]) -> dict[str, Any]:
        name, model = self._lookup(request)
        if model is None:
            kinds = {k.value: k for k in ModelKind}
            if name in kinds:
                await self.speech.run(kinds[name])
                return {"ok": True, "model": name}
            return {"ok": False, "error": f"'{name}' is not a model BigBro knows about."}
        await self.engine.run(model)
        return {"ok": True, "model": model.id}

    async def _control_models_stop(self, request: dict[str, Any]) -> dict[str, Any]:
        name, model = self._lookup(request)
        if model is None:
            kinds = {k.value: k for k in ModelKind}
            if name in kinds:
                self.speech.stop(kinds[name])
                return {"ok": True, "model": name}
            return {"ok": False, "error": f"'{name}' is not a model BigBro knows about."}
        self.engine.stop(model.id)
        return {"ok": True, "model": model.id}

    async def _control_models_remove(self, request: dict[str, Any]) -> dict[str, Any]:
        name, model = self._lookup(request)
        if model is None:
            kinds = {k.value: k for k in ModelKind}
            if name in kinds:
                self.speech.remove(kinds[name])
                return {"ok": True, "model": name}
            return {"ok": False, "error": f"'{name}' is not a model BigBro knows about."}
        self.engine.remove(model)
        return {"ok": True, "model": model.id}


def require_macos() -> None:
    """Refuses to start anywhere the MLX stack and the DNS-SD/IOKit bindings cannot work.

    Failing here with a clear message beats a ctypes error from deep inside the
    Bonjour binding several seconds later.
    """
    if sys.platform != "darwin":
        raise SystemExit(
            "bigbro serve requires macOS on Apple silicon — "
            f"this is {sys.platform}. The CLI's offline commands still work."
        )
