"""Text-to-speech (Kokoro) and speech-to-text (Parakeet) in-process via mlx-audio.

Replaces the Swift app's FluidAudio/CoreML path. Each model is tracked through the
same lifecycle as a catalog language model — not downloaded, downloading, downloaded,
starting, running, failed — so `bigbro models list` presents TTS and STT the same way
as Language and Vision, rather than as a single on/off switch for both. There is
deliberately no "enabled" flag: like a language model, a speech model starts lazily
on whichever request needs it first, or explicitly from the CLI.

The wire contract is unchanged from the Swift version: synthesis is always 24 kHz
16-bit mono PCM, because that is the only format Kokoro produces and the only one
BigBroKit's `BigBroAudioPlayer` is written to expect.
"""

from __future__ import annotations

import asyncio
import logging
import struct
from enum import Enum
from typing import AsyncIterator

import numpy as np

from .inference import catalog
from .inference.downloader import ModelDownloader

log = logging.getLogger("bigbro.speech")

SAMPLE_RATE = 24_000
CHUNK_BYTES = 8 * 1024

#: Used when a request names no voice. Not configurable here — voice selection is a
#: BigBroKit concern end to end (see `BigBroClient.defaultVoice`); this only covers a
#: raw wire request that omits `voice` entirely.
DEFAULT_VOICE = "af_heart"

_WAV_HEADER_BYTES = 44


class SpeechError(Exception):
    """Anything the client should see as an `error` message."""


class ModelKind(str, Enum):
    """A speech role, and by extension the model currently filling it.

    The role is what the wire addresses — an iOS client sends `run: tts`, never
    `run: kokoro` — so it stays the runtime key. Everything a person sees comes
    from the catalog entry behind it.
    """

    TTS = "tts"
    STT = "stt"

    @property
    def family(self) -> catalog.Family:
        return catalog.Family.TTS if self is ModelKind.TTS else catalog.Family.STT

    @property
    def model(self) -> catalog.BigBroModel:
        return catalog.speech_model(self.family)

    @property
    def model_name(self) -> str:
        return self.model.display_name

    @property
    def role(self) -> str:
        return "speech" if self is ModelKind.TTS else "transcription"

    @property
    def display_name(self) -> str:
        return f"{self.model_name} ({self.role})"

    @property
    def approximate_gb(self) -> float:
        return self.model.approximate_gb

    @property
    def repo(self) -> str:
        return self.model.repo

    @classmethod
    def for_family(cls, family: catalog.Family) -> "ModelKind":
        return cls.TTS if family is catalog.Family.TTS else cls.STT


def kinds_for(requested: str) -> list[ModelKind] | None:
    """The speech kinds a name refers to, or None if it isn't a speech request.

    Accepts the roles the wire sends (`tts`, `stt`, `speech`) and the model ids
    the panes display (`kokoro`, `parakeet`), so the name on screen is also a name
    that works.
    """
    models = catalog.resolve_speech(requested or "")
    if not models:
        return None
    return [ModelKind.for_family(m.family) for m in models]


def pcm16(samples: np.ndarray) -> bytes:
    """Converts float32 audio in [-1, 1] to little-endian 16-bit PCM.

    Clipped rather than scaled to peak: Kokoro occasionally overshoots slightly, and
    normalizing per chunk would make the volume pump between chunks of one utterance.
    """
    flat = np.asarray(samples, dtype=np.float32).reshape(-1)
    clipped = np.clip(flat, -1.0, 1.0)
    return (clipped * 32767.0).astype("<i2").tobytes()


def float_samples(audio: bytes, audio_format: str) -> np.ndarray:
    """Decodes an uploaded utterance to mono float32 at whatever rate it arrived in.

    Handles the headerless-PCM and WAV cases directly; anything else is refused rather
    than guessed at, since misreading a container yields noise that transcribes to
    plausible-looking nonsense.
    """
    fmt = (audio_format or "wav").lower()

    if fmt == "pcm":
        return np.frombuffer(audio, dtype="<i2").astype(np.float32) / 32768.0

    if fmt == "wav":
        if len(audio) < _WAV_HEADER_BYTES or audio[:4] != b"RIFF":
            raise SpeechError("Audio was not a valid WAV file.")
        # Walk the chunk list rather than assuming a 44-byte header — WAV files from
        # iOS often carry a LIST/INFO chunk ahead of the data.
        offset = 12
        channels, bits = 1, 16
        while offset + 8 <= len(audio):
            chunk_id = audio[offset:offset + 4]
            chunk_size = struct.unpack_from("<I", audio, offset + 4)[0]
            body = offset + 8
            if chunk_id == b"fmt ":
                channels = struct.unpack_from("<H", audio, body + 2)[0]
                bits = struct.unpack_from("<H", audio, body + 14)[0]
            elif chunk_id == b"data":
                payload = audio[body:body + chunk_size]
                if bits != 16:
                    raise SpeechError(f"Only 16-bit WAV audio is supported, got {bits}-bit.")
                samples = np.frombuffer(payload, dtype="<i2").astype(np.float32) / 32768.0
                if channels > 1:
                    samples = samples.reshape(-1, channels).mean(axis=1)
                return samples
            offset = body + chunk_size + (chunk_size % 2)
        raise SpeechError("WAV file contained no data chunk.")

    raise SpeechError(f"Unsupported audio format '{audio_format}'. Send wav or pcm.")


class SpeechEngine:
    """Kokoro TTS and Parakeet STT, with the same lifecycle as a catalog model."""

    def __init__(self, downloader: "ModelDownloader | None" = None) -> None:
        # The same downloader the language and vision models use. Fetching these
        # separately is what left them with no progress at all: the shared one
        # carries the tqdm plumbing, the up-front size, the allow_patterns and the
        # progress callback the daemon publishes from.
        from .inference.downloader import ModelDownloader

        self.downloader = downloader or ModelDownloader()
        self.record = self.downloader.record
        self._loaded: dict[ModelKind, object] = {}
        self._load_tasks: dict[ModelKind, asyncio.Task] = {}
        self._errors: dict[ModelKind, str] = {}
        # Same reason as MLXEngine: one Metal generation at a time.
        self._lock = asyncio.Lock()

    # MARK: - State

    def is_running(self, kind: ModelKind) -> bool:
        return kind in self._loaded

    def is_downloaded(self, kind: ModelKind) -> bool:
        return kind in self._loaded or self.record.is_downloaded(kind.model.id)

    def is_busy(self, kind: ModelKind) -> bool:
        return kind in self._load_tasks

    def state_description(self, kind: ModelKind) -> str:
        if kind in self._loaded:
            return "running"
        if kind in self._errors:
            return f"error: {self._errors[kind]}"
        if self.downloader.is_downloading(kind.model.id):
            progress = self.downloader.progress(kind.model.id)
            if progress is not None and progress.bytes_total:
                return f"downloading {round(progress.fraction * 100)}%"
            return "downloading"
        if kind in self._load_tasks:
            return "starting"
        return "downloaded" if self.is_downloaded(kind) else "not downloaded"

    # MARK: - Lifecycle

    async def download(self, kind: ModelKind) -> None:
        """Fetches the weights, reporting progress like any other model."""
        await self.downloader.download(kind.model)

    async def run(self, kind: ModelKind):
        loaded = self._loaded.get(kind)
        if loaded is not None:
            return loaded

        existing = self._load_tasks.get(kind)
        if existing is not None:
            return await existing

        task = asyncio.create_task(self._load(kind))
        self._load_tasks[kind] = task
        try:
            return await task
        finally:
            self._load_tasks.pop(kind, None)

    async def _load(self, kind: ModelKind):
        try:
            await self.download(kind)
            log.info("loading %s", kind.display_name)
            loaded = await asyncio.to_thread(self._load_blocking, kind)
        except Exception as exc:
            self._errors[kind] = str(exc)
            log.error("failed to load %s: %s", kind.display_name, exc)
            raise SpeechError(f"Could not load {kind.display_name}: {exc}") from exc

        self._loaded[kind] = loaded
        self._errors.pop(kind, None)
        log.info("%s is running", kind.display_name)
        return loaded

    @staticmethod
    def _load_blocking(kind: ModelKind):
        if kind is ModelKind.TTS:
            from mlx_audio.tts.utils import load_model as load_tts
            return load_tts(kind.repo)

        from mlx_audio.stt.utils import load_model as load_stt
        return load_stt(kind.repo)

    def stop(self, kind: ModelKind) -> None:
        if self._loaded.pop(kind, None) is None:
            return
        self._errors.pop(kind, None)
        log.info("stopped %s", kind.display_name)
        try:
            import mlx.core as mx
            mx.clear_cache()
        except Exception:  # pragma: no cover - depends on the MLX version
            pass

    def remove(self, kind: ModelKind) -> None:
        self.stop(kind)
        self.downloader.remove(kind.model)

    # MARK: - Synthesis

    async def synthesize(
        self, text: str, voice: str | None = None, speed: float | None = None
    ) -> AsyncIterator[bytes]:
        """Streams 24 kHz 16-bit mono PCM in ~8 KB chunks."""
        model = await self.run(ModelKind.TTS)
        chosen_voice = voice or DEFAULT_VOICE

        async with self._lock:
            audio = await asyncio.to_thread(
                self._synthesize_blocking, model, text, chosen_voice, speed or 1.0
            )

        raw = pcm16(audio)
        for start in range(0, len(raw), CHUNK_BYTES):
            yield raw[start:start + CHUNK_BYTES]

    @staticmethod
    def _synthesize_blocking(model, text: str, voice: str, speed: float) -> np.ndarray:
        segments = []
        for result in model.generate(text=text, voice=voice, speed=speed):
            audio = getattr(result, "audio", result)
            segments.append(np.asarray(audio, dtype=np.float32).reshape(-1))
        if not segments:
            raise SpeechError("Kokoro produced no audio for that input.")
        return np.concatenate(segments)

    # MARK: - Transcription

    async def transcribe(self, audio: bytes, audio_format: str = "wav") -> tuple[str, str | None]:
        model = await self.run(ModelKind.STT)
        samples = float_samples(audio, audio_format)
        if samples.size == 0:
            raise SpeechError("Audio contained no samples.")

        async with self._lock:
            result = await asyncio.to_thread(model.generate, samples)

        text = getattr(result, "text", None)
        if text is None:
            text = str(result)
        language = getattr(result, "language", None)
        return text.strip(), language
