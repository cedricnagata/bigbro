"""Where bigbro keeps its state on disk.

Replaces the `UserDefaults` the menu-bar app used. A terminal daemon has no
app bundle and no defaults domain, and a plain JSON file is inspectable and
editable — which matters when the only UI is a CLI.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

log = logging.getLogger("bigbro.config")

DEFAULT_PORT = 8765


def support_dir() -> Path:
    """The directory holding devices, download records and the control socket.

    Honours `BIGBRO_HOME` so a test — or a second instance on the same Mac — can be
    pointed somewhere else without touching the real one.
    """
    override = os.environ.get("BIGBRO_HOME")
    root = Path(override) if override else Path.home() / "Library" / "Application Support" / "bigbro"
    root.mkdir(parents=True, exist_ok=True)
    return root


def control_socket_path() -> Path:
    return support_dir() / "control.sock"


@dataclass
class Settings:
    """What the daemon reads from `config.json`, and what the Settings pane edits.

    CLI flags always win over the file. A flag is what someone typed for this run;
    the file is what they left configured — silently overriding the explicit one
    with the remembered one would make `--port` look broken.
    """

    port: int = DEFAULT_PORT
    keep_awake: bool = True
    log_level: str = "INFO"

    #: Fields a client may write via the Settings pane, with their validators.
    EDITABLE = ("port", "keep_awake", "log_level")

    @classmethod
    def load(cls, store: "JSONStore | None" = None) -> "Settings":
        store = store or JSONStore(support_dir() / "config.json")
        return cls(
            port=_as_port(store.get("port"), DEFAULT_PORT),
            keep_awake=bool(store.get("keep_awake", True)),
            log_level=_as_log_level(store.get("log_level"), "INFO"),
        )

    def save(self, store: "JSONStore | None" = None) -> None:
        store = store or JSONStore(support_dir() / "config.json")
        store.update({
            "port": self.port,
            "keep_awake": self.keep_awake,
            "log_level": self.log_level,
        })

    def apply(self, key: str, value: Any) -> "tuple[bool, str]":
        """Validates and applies one edit. Returns (changed, message).

        Rejects rather than coerces: a port silently clamped into range is a
        daemon listening somewhere the user did not ask for.
        """
        if key not in self.EDITABLE:
            return False, f"'{key}' is not a setting"

        if key == "port":
            try:
                port = int(value)
            except (TypeError, ValueError):
                return False, f"port must be a number, got {value!r}"
            if not 1024 <= port <= 65535:
                return False, f"port must be between 1024 and 65535, got {port}"
            if port == self.port:
                return False, "unchanged"
            self.port = port
            return True, "port set — restart the daemon for it to take effect"

        if key == "keep_awake":
            wanted = value if isinstance(value, bool) else str(value).lower() in ("1", "true", "yes", "on")
            if wanted == self.keep_awake:
                return False, "unchanged"
            self.keep_awake = wanted
            return True, "keep-awake " + ("enabled" if wanted else "disabled")

        level = str(value).upper()
        if level not in _LOG_LEVELS:
            return False, f"log level must be one of {', '.join(_LOG_LEVELS)}"
        if level == self.log_level:
            return False, "unchanged"
        self.log_level = level
        return True, f"log level set to {level}"

    def to_wire(self) -> dict[str, Any]:
        return {"port": self.port, "keep_awake": self.keep_awake, "log_level": self.log_level}


_LOG_LEVELS = ("DEBUG", "INFO", "WARNING", "ERROR")


def _as_port(value: Any, default: int) -> int:
    try:
        port = int(value)
    except (TypeError, ValueError):
        return default
    return port if 1024 <= port <= 65535 else default


def _as_log_level(value: Any, default: str) -> str:
    level = str(value).upper() if value is not None else default
    return level if level in _LOG_LEVELS else default


class JSONStore:
    """A dict persisted to one JSON file, written atomically.

    Atomic because the daemon and a `bigbro pair` invocation can both be running: a
    torn write would leave the device list unreadable, which locks every paired
    device out until someone deletes the file by hand.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self._data: dict[str, Any] = self._read()

    def _read(self) -> dict[str, Any]:
        try:
            with self.path.open(encoding="utf-8") as handle:
                data = json.load(handle)
            return data if isinstance(data, dict) else {}
        except FileNotFoundError:
            return {}
        except (json.JSONDecodeError, OSError) as exc:
            log.error("could not read %s (%s) — starting empty", self.path, exc)
            return {}

    def reload(self) -> None:
        self._data = self._read()

    def get(self, key: str, default: Any = None) -> Any:
        return self._data.get(key, default)

    def set(self, key: str, value: Any) -> None:
        self._data[key] = value
        self.flush()

    def update(self, values: dict[str, Any]) -> None:
        self._data.update(values)
        self.flush()

    def delete(self, key: str) -> None:
        if self._data.pop(key, None) is not None:
            self.flush()

    def keys(self) -> list[str]:
        return list(self._data)

    def flush(self) -> None:
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        try:
            with tmp.open("w", encoding="utf-8") as handle:
                json.dump(self._data, handle, indent=2, sort_keys=True)
            os.replace(tmp, self.path)
        except OSError as exc:
            log.error("could not write %s: %s", self.path, exc)
            tmp.unlink(missing_ok=True)
