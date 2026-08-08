"""A daemon stand-in that answers control commands, without any inference.

Lives in its own module rather than beside the tests that use it because it
outlives them: the Swift client's conformance test drives this same stub through
`serve_stub.py`, and a stub that disappeared with a deleted test file would take
that coverage with it.
"""

from __future__ import annotations


class StubDaemon:
    """Answers the control commands a dashboard issues, and records them."""

    def __init__(self) -> None:
        from bigbro.events import EventBus

        self.bus = EventBus()
        self.calls: list[dict] = []
        self.pending: list[dict] = []
        self.devices: list[dict] = [
            {"deviceId": "device-abc123", "name": "iPhone", "appName": "TestApp",
             "connected": True, "requiredModels": ["qwen3-4b"]},
        ]
        self.models: list[dict] = [
            {"id": "qwen3-4b", "name": "Qwen3 4B", "family": "language", "state": "not downloaded",
             "sizeGB": 2.4, "tools": True, "images": False, "reasoning": "think_tags_togglable"},
            {"id": "gpt-oss-20b", "name": "gpt-oss 20B", "family": "language", "state": "running",
             "sizeGB": 12.0, "tools": True, "images": False, "reasoning": "harmony"},
            {"id": "llama-3.2-1b", "name": "Llama 3.2 1B", "family": "language",
             "state": "downloaded", "sizeGB": 0.7, "tools": True, "images": False,
             "reasoning": "none"},
        ]
        self.vision: list[dict] = [
            {"id": "qwen2.5-vl-3b", "name": "Qwen2.5-VL 3B", "family": "vision",
             "state": "not downloaded", "sizeGB": 2.0, "tools": False, "images": True,
             "reasoning": "none"},
        ]
        self.tts: list[dict] = [
            {"id": "kokoro", "name": "Kokoro 82M", "family": "tts", "state": "not downloaded",
             "sizeGB": 0.7, "tools": False, "images": False, "reasoning": "none"},
        ]
        self.stt: list[dict] = [
            {"id": "parakeet", "name": "Parakeet TDT 0.6B v3", "family": "stt",
             "state": "not downloaded", "sizeGB": 2.5, "tools": False, "images": False,
             "reasoning": "none"},
        ]
        self.settings = {"port": 8765, "keep_awake": True, "log_level": "INFO"}

    async def handle(self, request: dict) -> dict:
        self.calls.append(request)
        command = request.get("command")

        if command == "status":
            return {
                "ok": True, "name": "Test Mac", "port": 8765, "keepAwake": True,
                "paired": len(self.devices),
                "connected": [d["deviceId"] for d in self.devices if d["connected"]],
                "pending": self.pending, "running": ["gpt-oss-20b"], "downloaded": ["gpt-oss-20b"],
                "speech": {"tts": "not downloaded", "stt": "not downloaded"},
            }
        if command == "pair.list":
            return {"ok": True, "pending": self.pending, "devices": self.devices}
        if command in ("pair.approve", "pair.deny"):
            device_id = request.get("deviceId")
            self.pending = [p for p in self.pending if p["deviceId"] != device_id]
            return {"ok": True, "deviceId": device_id, "deviceName": "iPhone",
                    "approved": command == "pair.approve"}
        if command == "pair.remove":
            self.devices = [d for d in self.devices if d["deviceId"] != request.get("deviceId")]
            return {"ok": True, "deviceId": request.get("deviceId"), "name": "iPhone"}
        if command == "models.list":
            return {"ok": True, "groups": [
                {"family": "language", "label": "Text", "models": self.models},
                {"family": "vision", "label": "Vision", "models": self.vision},
                {"family": "tts", "label": "TTS", "models": self.tts},
                {"family": "stt", "label": "STT", "models": self.stt},
            ]}
        if command in ("models.start", "models.stop", "models.download", "models.delete"):
            return {"ok": True, "model": request.get("model")}
        if command == "settings.get":
            return {"ok": True, "settings": self.settings,
                    "editable": ["port", "keep_awake", "log_level"]}
        if command == "settings.set":
            key, value = request.get("key"), request.get("value")
            if key == "port" and str(value) == "80":
                return {"ok": False, "error": "port must be between 1024 and 65535, got 80"}
            self.settings[key] = value
            return {"ok": True, "message": "saved", "settings": self.settings}
        return {"ok": False, "error": f"unknown command '{command}'"}

    def sort_like_the_daemon(self) -> None:
        """Mirrors the daemon's ordering, which is where sorting actually happens."""
        from bigbro.daemon import Daemon

        for group in ("models", "vision", "tts", "stt"):
            setattr(self, group, sorted(
                getattr(self, group), key=lambda e: Daemon._state_rank(e["state"])
            ))

    def commands(self) -> list[str]:
        return [c.get("command") for c in self.calls]
