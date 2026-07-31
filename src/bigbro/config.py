"""Where bigbro keeps its state on disk.

Replaces the `UserDefaults` the menu-bar app used. A terminal daemon has no
app bundle and no defaults domain, and a plain JSON file is inspectable and
editable — which matters when the only UI is a CLI.
"""

from __future__ import annotations

import json
import logging
import os
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
