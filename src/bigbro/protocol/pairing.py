"""Device approval and persistence. Port of Server/PairingManager.swift.

The one real behavioural change in the terminal pivot lives here. The menu-bar app
showed a modal `NSAlert` and blocked on it; a daemon has no window to show and may
not even have a TTY, so an unknown device's `hello` is *parked* — the connection
stays open, unregistered, while the request sits in a queue that `bigbro pair list`
reads and `bigbro pair approve` resolves.

Parking needs a timeout the modal never did. A modal cannot be ignored forever
without someone noticing; a queued request can, and each one holds a live socket.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Callable

from ..config import JSONStore, support_dir

log = logging.getLogger("bigbro.pairing")

#: How long an unapproved device's connection is held open waiting for a decision.
#: After this it is denied and closed — it can always reconnect and ask again.
PENDING_TIMEOUT_SECONDS = 300


@dataclass
class PendingRequest:
    device_id: str
    device_name: str
    app_name: str
    required_models: list[str]
    connection_id: str
    requested_at: float = field(default_factory=time.monotonic)
    decision: asyncio.Future = field(default_factory=asyncio.Future)

    @property
    def waiting_seconds(self) -> float:
        return time.monotonic() - self.requested_at

    def to_wire(self) -> dict[str, Any]:
        return {
            "deviceId": self.device_id,
            "deviceName": self.device_name,
            "appName": self.app_name,
            "requiredModels": self.required_models,
            "waitingSeconds": round(self.waiting_seconds),
        }


class PairingManager:
    """Remembers approved devices and gates new ones behind an explicit decision."""

    def __init__(self, store: JSONStore | None = None) -> None:
        self._store = store or JSONStore(support_dir() / "devices.json")
        self._approved: set[str] = set(self._store.get("approvedDevices", []))
        self._names: dict[str, str] = dict(self._store.get("deviceNames", {}))
        self._app_names: dict[str, str] = dict(self._store.get("deviceAppNames", {}))
        self._required_models: dict[str, list[str]] = {}
        self._connected: set[str] = set()
        self._pending: dict[str, PendingRequest] = {}

        #: Set by the daemon. Returns True when a model a client declared is ready.
        self.is_model_satisfied: Callable[[str], bool] = lambda _name: True

        #: Set by the daemon. Publishes to attached UIs; a no-op when none exist,
        #: which keeps pairing testable without standing up an event bus.
        self.publish: Callable[..., None] = lambda _event, **_fields: None

        log.info("loaded %d approved device(s)", len(self._approved))

    # MARK: - Queries

    @property
    def approved_device_ids(self) -> list[str]:
        return sorted(self._approved)

    @property
    def connected_device_ids(self) -> set[str]:
        return set(self._connected)

    @property
    def pending_requests(self) -> list[PendingRequest]:
        return list(self._pending.values())

    def display_name(self, device_id: str) -> str:
        device = self._names.get(device_id, device_id)
        app = self._app_names.get(device_id)
        return f"{device} • {app}" if app else device

    def required_models(self, device_id: str) -> list[str]:
        return self._required_models.get(device_id, [])

    def missing_models(self, required: list[str]) -> list[str]:
        """A client's declared models that aren't ready.

        Resolved through the catalog rather than matched exactly, because older
        clients send Ollama-style tags. A name matching nothing is not reported
        missing — there is no model to pull for it, so offering one is a dead end.
        """
        return [name for name in required if not self.is_model_satisfied(name)]

    def describe(self, device_id: str) -> dict[str, Any]:
        return {
            "deviceId": device_id,
            "name": self._names.get(device_id, device_id),
            "appName": self._app_names.get(device_id, ""),
            "connected": device_id in self._connected,
            "requiredModels": self._required_models.get(device_id, []),
        }

    # MARK: - Connection state

    def mark_connected(self, device_id: str) -> None:
        self._connected.add(device_id)
        log.info("%s connected (%d total)", device_id[:8], len(self._connected))

    def mark_disconnected(self, device_id: str) -> None:
        self._connected.discard(device_id)
        self._required_models.pop(device_id, None)
        log.info("%s disconnected (%d total)", device_id[:8], len(self._connected))

    # MARK: - Pairing

    def is_approved(self, device_id: str) -> bool:
        return device_id in self._approved

    async def await_decision(
        self,
        device_id: str,
        device_name: str,
        app_name: str,
        required_models: list[str],
        connection_id: str,
    ) -> bool:
        """Parks an unknown device until someone approves it, denies it, or it times out.

        Returns True if it was approved. A second `hello` from a device already
        waiting replaces the first request rather than queueing two — a client
        retrying its handshake is still one device asking one question.
        """
        previous = self._pending.pop(device_id, None)
        if previous is not None and not previous.decision.done():
            previous.decision.set_result(False)

        request = PendingRequest(
            device_id=device_id,
            device_name=device_name,
            app_name=app_name,
            required_models=required_models,
            connection_id=connection_id,
        )
        self._pending[device_id] = request

        log.warning(
            "'%s' (%s) wants to pair — approve in the dashboard, or run: bigbro pair approve %s",
            device_name, app_name, device_id[:8],
        )
        self.publish("pairing.requested", **request.to_wire())

        try:
            approved = await asyncio.wait_for(request.decision, timeout=PENDING_TIMEOUT_SECONDS)
        except asyncio.TimeoutError:
            log.warning(
                "pairing request from '%s' timed out after %ds — denying",
                device_name, PENDING_TIMEOUT_SECONDS,
            )
            self.publish("pairing.resolved", deviceId=device_id, approved=False, timedOut=True)
            return False
        else:
            self.publish("pairing.resolved", deviceId=device_id, approved=approved, timedOut=False)
            return approved
        finally:
            # Only retract *this* request. A retrying client replaces its own earlier
            # request, and popping by device id alone would remove the replacement —
            # leaving a live connection parked against a queue entry nobody can see.
            if self._pending.get(device_id) is request:
                del self._pending[device_id]

    def resolve_pending(self, device_id_prefix: str, approved: bool) -> PendingRequest | None:
        """Answers a parked request, matched by full device id or unambiguous prefix.

        Returns the request that was resolved, or None if nothing matched. An
        ambiguous prefix matches nothing rather than picking one — approving the wrong
        device is not a mistake worth guessing into.
        """
        matches = [
            request for device_id, request in self._pending.items()
            if device_id == device_id_prefix or device_id.startswith(device_id_prefix)
        ]
        if len(matches) != 1:
            return None

        request = matches[0]
        if not request.decision.done():
            request.decision.set_result(approved)
        return request

    def approve(self, device_id: str, device_name: str, app_name: str, required_models: list[str]) -> None:
        self._approved.add(device_id)
        self._names[device_id] = device_name
        self._app_names[device_id] = app_name
        self._required_models[device_id] = required_models
        self._persist()

    def note_seen(self, device_id: str, device_name: str, app_name: str, required_models: list[str]) -> None:
        """Refreshes what an already-approved device calls itself, without re-approving."""
        changed = False
        if self._names.get(device_id) != device_name:
            self._names[device_id] = device_name
            changed = True
        if self._app_names.get(device_id) != app_name:
            self._app_names[device_id] = app_name
            changed = True
        self._required_models[device_id] = required_models
        if changed:
            self._persist()

    def remove(self, device_id: str) -> bool:
        if device_id not in self._approved:
            return False
        self._approved.discard(device_id)
        self._names.pop(device_id, None)
        self._app_names.pop(device_id, None)
        self._required_models.pop(device_id, None)
        self._connected.discard(device_id)
        self._persist()
        log.info("removed device %s", device_id[:8])
        return True

    def remove_all(self) -> int:
        count = len(self._approved)
        self._approved.clear()
        self._names.clear()
        self._app_names.clear()
        self._required_models.clear()
        self._connected.clear()
        self._persist()
        log.info("removed all %d device(s)", count)
        return count

    def resolve_device_id(self, prefix: str) -> str | None:
        """Full device id for a prefix the user typed, or None if it isn't unambiguous."""
        if prefix in self._approved:
            return prefix
        matches = [device_id for device_id in self._approved if device_id.startswith(prefix)]
        return matches[0] if len(matches) == 1 else None

    def _persist(self) -> None:
        self._store.update({
            "approvedDevices": sorted(self._approved),
            "deviceNames": self._names,
            "deviceAppNames": self._app_names,
        })
