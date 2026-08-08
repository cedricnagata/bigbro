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

from .config import Settings
from .control import ControlServer
from .events import EventBus
from .inference import catalog
from .inference.downloader import ModelDownloader, Progress
from .inference.engine import MLXEngine
from .macos import memory as memory_probe
from .macos.bonjour import BonjourAdvertiser, computer_name
from .macos.power import PowerAssertion
from .protocol.pairing import PairingManager
from .protocol.server import PeerServer
from .router import AppRouter
from .speech import ModelKind, SpeechEngine, kinds_for

log = logging.getLogger("bigbro.daemon")


class Daemon:
    def __init__(
        self,
        port: int | None = None,
        keep_awake: bool | None = None,
        settings: Settings | None = None,
    ) -> None:
        # Flags win over the file: a flag is what someone typed for this run, the
        # file is what they left configured.
        self.settings = settings or Settings.load()
        if port is not None:
            self.settings.port = port
        if keep_awake is not None:
            self.settings.keep_awake = keep_awake

        self.events = EventBus()
        self.downloader = ModelDownloader()
        self.engine = MLXEngine(self.downloader)
        self.speech = SpeechEngine(self.downloader)
        self.pairing = PairingManager()
        self.server = PeerServer()
        self.advertiser = BonjourAdvertiser()
        self.power = PowerAssertion()
        self.router = AppRouter(self.server, self.pairing, self.engine, self.speech)
        self.control = ControlServer(self.handle_control, bus=self.events)

        self.server.delegate = self.router
        self.pairing.is_model_satisfied = self.engine.is_required_model_satisfied
        self.pairing.publish = self.events.publish
        self.router.on_peer_change = self._on_peer_change
        self.router.on_model_change = self._publish_model_state
        self.engine.on_state_change = self._publish_model_state
        # Speech is a second engine with a second lifecycle, and it needs the hook
        # for the same reason the first one did.
        self.speech.on_state_change = self._publish_model_state
        self.downloader.on_progress = self._on_download_progress

        self._stopping = asyncio.Event()
        self._loop: asyncio.AbstractEventLoop | None = None

    @property
    def port(self) -> int:
        return self.settings.port

    @property
    def keep_awake(self) -> bool:
        return self.settings.keep_awake

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
        """Broadcasts progress to every connected peer, and to attached UIs.

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

        self.events.publish(
            "download.progress",
            model=model_id,
            status=progress.status,
            completed=progress.bytes_completed,
            total=progress.bytes_total,
            fraction=progress.fraction,
            done=progress.done,
            error=progress.error,
            state=self._state_of(model_id),
        )

        if self._loop is not None:
            asyncio.ensure_future(self.server.broadcast(message))
            if progress.done:
                # The completion event is emitted from inside the download task, so
                # the model still counts as downloading when its state is read for
                # that event — the row would sit at "downloading 100%" until the
                # next poll. Re-publish once the task has actually been retired.
                asyncio.ensure_future(self._publish_settled_state(model_id))

    async def _publish_settled_state(self, model_id: str) -> None:
        self._publish_model_state(model_id)

    def _on_peer_change(self, device_id: str, connected: bool) -> None:
        """Announces a device connecting or dropping, so the Devices pane can move."""
        self.events.publish(
            "peer.connected" if connected else "peer.disconnected",
            deviceId=device_id,
            name=self.pairing.display_name(device_id),
            connected=self.server.connected_device_ids,
        )

    def _state_of(self, model_id: str) -> str:
        """A model's state, from whichever engine owns it.

        Speech models are not in MLXEngine's bookkeeping, so asking it about
        Kokoro would answer from the download record alone and never report
        "running".
        """
        model = next((m for m in catalog.EVERY_MODEL if m.id == model_id), None)
        if model is not None and model.family.is_speech:
            return self.speech.state_description(ModelKind.for_family(model.family))
        return self.engine.state_description(model_id)

    def _publish_model_state(self, model_id: str) -> None:
        self.events.publish("model.state", model=model_id, state=self._state_of(model_id))

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
            "models.start": self._control_models_start,
            "models.delete": self._control_models_delete,
            # The pre-rename names, so a CLI or dashboard from either side of the
            # change still talks to a daemon from the other.
            "models.run": self._control_models_start,
            "models.stop": self._control_models_stop,
            "models.remove": self._control_models_delete,
            "settings.get": self._control_settings_get,
            "settings.set": self._control_settings_set,
            "daemon.shutdown": self._control_shutdown,
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
                kind.value: {
                    "name": kind.model_name,
                    "model": kind.model.id,
                    "state": self.speech.state_description(kind),
                }
                for kind in ModelKind
            },
            "memory": memory_probe.report(self.engine.memory_by_model).to_wire(),
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

    #: How far along a model is, for ordering. What is usable comes first, what would
    #: cost a download comes last, and the transient states sit between in the order
    #: they actually happen.
    _STATE_RANK = {
        "running": 0,
        "starting": 1,
        "downloading": 2,
        "downloaded": 3,
        "error": 4,
        "not downloaded": 5,
    }

    @classmethod
    def _state_rank(cls, state: str) -> int:
        """Rank for a state description, which may carry a percentage or a message."""
        for prefix, rank in cls._STATE_RANK.items():
            if state.startswith(prefix):
                return rank
        return len(cls._STATE_RANK)

    def _model_entry(self, model) -> dict[str, Any]:
        """One row, with its state read from whichever engine owns it."""
        if model.family.is_speech:
            state = self.speech.state_description(ModelKind.for_family(model.family))
            memory = None
        else:
            state = self.engine.state_description(model.id)
            memory = self.engine.memory_by_model.get(model.id)
        return {
            "id": model.id,
            "name": model.display_name,
            "family": model.family.value,
            "state": state,
            "sizeGB": model.approximate_gb,
            "tools": model.supports_tools,
            "images": model.supports_images,
            "reasoning": model.reasoning.value,
            "memory": memory,
        }

    async def _control_models_list(self, _request: dict[str, Any]) -> dict[str, Any]:
        """Grouped by family, because these are not interchangeable.

        A language model has no vision tower and a speech model answers nothing at
        all, so presenting them as one list invites naming the wrong kind — which
        fails rather than degrading.
        """
        return {
            "ok": True,
            "groups": [
                {
                    "family": family.value,
                    "label": family.label,
                    # Sorted here rather than in each renderer, so the CLI and every
                    # pane agree. `sorted` is stable, so models at the same stage keep
                    # their catalog order — which is curated, not alphabetical.
                    "models": sorted(
                        (self._model_entry(m) for m in catalog.models_in(family)),
                        key=lambda entry: self._state_rank(entry["state"]),
                    ),
                }
                for family in catalog.Family
            ],
        }

    def _lookup(self, request: dict[str, Any]):
        """Resolves a model name to (name, inference_model, speech_kinds).

        Speech is matched by role (`tts`, `stt`, `speech`) *and* by model id
        (`kokoro`, `parakeet`), so whatever the panes display can also be typed.
        """
        name = str(request.get("model") or "")
        return name, catalog.resolve(name), kinds_for(name) or []

    @staticmethod
    def _unknown(name: str) -> dict[str, Any]:
        return {"ok": False, "error": f"'{name}' is not a model BigBro knows about."}

    async def _control_models_download(self, request: dict[str, Any]) -> dict[str, Any]:
        name, model, kinds = self._lookup(request)
        if model is not None:
            asyncio.ensure_future(self.router._download_quietly(model))  # noqa: SLF001
            return {"ok": True, "model": model.id, "started": True}
        if kinds:
            for kind in kinds:
                asyncio.ensure_future(self.speech.download(kind))
            return {"ok": True, "model": ", ".join(k.model.id for k in kinds), "started": True}
        return self._unknown(name)

    async def _control_models_start(self, request: dict[str, Any]) -> dict[str, Any]:
        name, model, kinds = self._lookup(request)
        if model is None:
            if not kinds:
                return self._unknown(name)
            for kind in kinds:
                await self.speech.run(kind)
            return {"ok": True, "model": ", ".join(k.model.id for k in kinds)}
        # Loading a 12 GB model takes long enough that holding the control reply
        # would look like the UI had frozen. Report state through events instead.
        self._publish_model_state(model.id)
        asyncio.ensure_future(self._run_and_publish(model))
        return {"ok": True, "model": model.id, "started": True}

    async def _run_and_publish(self, model) -> None:
        try:
            await self.engine.run(model)
        except Exception as exc:
            log.error("run failed for %s: %s", model.id, exc)
        self._publish_model_state(model.id)

    async def _control_models_stop(self, request: dict[str, Any]) -> dict[str, Any]:
        name, model, kinds = self._lookup(request)
        if model is None:
            if not kinds:
                return self._unknown(name)
            for kind in kinds:
                self.speech.stop(kind)
            return {"ok": True, "model": ", ".join(k.model.id for k in kinds)}
        self.engine.stop(model.id)
        self._publish_model_state(model.id)
        return {"ok": True, "model": model.id}

    async def _control_models_delete(self, request: dict[str, Any]) -> dict[str, Any]:
        name, model, kinds = self._lookup(request)
        if model is None:
            if not kinds:
                return self._unknown(name)
            for kind in kinds:
                self.speech.remove(kind)
            return {"ok": True, "model": ", ".join(k.model.id for k in kinds)}
        self.engine.remove(model)
        self._publish_model_state(model.id)
        return {"ok": True, "model": model.id}

    # MARK: - Settings

    async def _control_shutdown(self, _request: dict[str, Any]) -> dict[str, Any]:
        """Stops the daemon, on purpose, from somewhere else.

        Until now the only ways to stop a daemon were Ctrl-C in whichever terminal
        started it, or finding its pid. That leaves an orphan — a daemon whose UI
        crashed, or one started in a terminal window since closed — holding the
        Mac awake with nothing obvious to stop it. BigBro.app cannot send SIGTERM
        to a process it did not spawn, but it is already holding this socket.

        The stop is scheduled rather than immediate: `stop()` sets the event
        `run()` is waiting on, and shutdown closes this very socket. Firing it
        now would race the reply, and the caller would see the connection drop
        instead of an acknowledgement.
        """
        log.info("shutdown requested over the control socket")
        loop = asyncio.get_running_loop()
        loop.call_later(0.1, self.stop)
        return {"ok": True, "stopping": True}

    async def _control_settings_get(self, _request: dict[str, Any]) -> dict[str, Any]:
        return {"ok": True, "settings": self.settings.to_wire(), "editable": list(Settings.EDITABLE)}

    async def _control_settings_set(self, request: dict[str, Any]) -> dict[str, Any]:
        key = str(request.get("key") or "")
        changed, message = self.settings.apply(key, request.get("value"))
        if not changed:
            return {"ok": False, "error": message}

        self.settings.save()

        # Some settings take effect now; port needs a restart, and `apply` says so.
        if key == "keep_awake":
            if self.settings.keep_awake:
                self.power.acquire("bigbro is serving nearby devices")
            else:
                self.power.release()
        elif key == "log_level":
            logging.getLogger("bigbro").setLevel(self.settings.log_level)

        log.info("setting changed: %s — %s", key, message)
        self.events.publish("settings.changed", settings=self.settings.to_wire())
        return {"ok": True, "message": message, "settings": self.settings.to_wire()}


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
