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
import pathlib
import queue
import struct
from enum import Enum
from typing import AsyncIterator

import numpy as np

from .inference import catalog, mlx_thread
from .inference.downloader import ModelDownloader

log = logging.getLogger("bigbro.speech")

SAMPLE_RATE = 24_000
CHUNK_BYTES = 8 * 1024

#: Used when a request names no voice. Not configurable here — voice selection is a
#: BigBroKit concern end to end (see `BigBroClient.defaultVoice`); this only covers a
#: raw wire request that omits `voice` entirely.
DEFAULT_VOICE = "af_heart"

_WAV_HEADER_BYTES = 44

#: Pushed onto the bridge when a synthesis run finishes.
_SYNTHESIS_DONE = object()


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


def resample(samples: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    """Linear resample to `target_rate`.

    Parakeet is handed raw samples and applies its own configured rate to them, so
    a 24 kHz utterance passed through untouched is transcribed as though it were
    16 kHz — faster and higher, which comes back as plausible-looking wrong words
    rather than an error.
    """
    if source_rate == target_rate or samples.size == 0:
        return samples
    duration = samples.size / source_rate
    target_length = max(1, int(round(duration * target_rate)))
    source_x = np.arange(samples.size, dtype=np.float64)
    target_x = np.linspace(0, samples.size - 1, target_length, dtype=np.float64)
    return np.interp(target_x, source_x, samples).astype(np.float32)


def float_samples(audio: bytes, audio_format: str) -> tuple[np.ndarray, int]:
    """Decodes an uploaded utterance to (mono float32, sample rate).

    Handles the headerless-PCM and WAV cases directly; anything else is refused rather
    than guessed at, since misreading a container yields noise that transcribes to
    plausible-looking nonsense.
    """
    fmt = (audio_format or "wav").lower()

    if fmt == "pcm":
        # Headerless PCM says nothing about itself; BigBroKit records at the rate
        # it synthesizes at, so that is the only defensible assumption.
        return np.frombuffer(audio, dtype="<i2").astype(np.float32) / 32768.0, SAMPLE_RATE

    if fmt == "wav":
        if len(audio) < _WAV_HEADER_BYTES or audio[:4] != b"RIFF":
            raise SpeechError("Audio was not a valid WAV file.")
        # Walk the chunk list rather than assuming a 44-byte header — WAV files from
        # iOS often carry a LIST/INFO chunk ahead of the data.
        offset = 12
        channels, bits, rate = 1, 16, SAMPLE_RATE
        while offset + 8 <= len(audio):
            chunk_id = audio[offset:offset + 4]
            chunk_size = struct.unpack_from("<I", audio, offset + 4)[0]
            body = offset + 8
            if chunk_id == b"fmt ":
                channels = struct.unpack_from("<H", audio, body + 2)[0]
                rate = struct.unpack_from("<I", audio, body + 4)[0] or SAMPLE_RATE
                bits = struct.unpack_from("<H", audio, body + 14)[0]
            elif chunk_id == b"data":
                payload = audio[body:body + chunk_size]
                if bits != 16:
                    raise SpeechError(f"Only 16-bit WAV audio is supported, got {bits}-bit.")
                samples = np.frombuffer(payload, dtype="<i2").astype(np.float32) / 32768.0
                if channels > 1:
                    samples = samples.reshape(-1, channels).mean(axis=1)
                return samples, rate
            offset = body + chunk_size + (chunk_size % 2)
        raise SpeechError("WAV file contained no data chunk.")

    # Anything else goes through CoreAudio. iOS records to m4a by default —
    # `AVAudioRecorder` with `kAudioFormatMPEG4AAC` — so refusing it would push a
    # transcode onto every client for the most ordinary way to capture audio on
    # the platform bigbro exists to serve.
    return _decode_via_coreaudio(audio, fmt)


#: Formats handed to `afconvert`. Not an exhaustive list of what CoreAudio reads;
#: it is what a client is plausibly going to send.
COMPRESSED_FORMATS = ("m4a", "mp4", "aac", "caf", "aiff", "aif", "mp3", "flac", "alac")


def _decode_via_coreaudio(audio: bytes, fmt: str) -> tuple[np.ndarray, int]:
    """Decodes with `afconvert`, which ships with macOS.

    Shelling out rather than adding a decoding dependency, the same reasoning as
    `scutil` for the computer name: the platform already has this, and it
    understands every container CoreAudio does.
    """
    import shutil
    import subprocess
    import tempfile

    if fmt not in COMPRESSED_FORMATS:
        raise SpeechError(
            f"Unsupported audio format '{fmt}'. Send wav, pcm, or one of: "
            f"{', '.join(COMPRESSED_FORMATS)}."
        )
    if shutil.which("afconvert") is None:  # pragma: no cover - always present on macOS
        raise SpeechError(f"Cannot decode '{fmt}' — afconvert is not available.")

    with tempfile.TemporaryDirectory(prefix="bigbro-audio-") as workspace:
        source = pathlib.Path(workspace) / f"input.{fmt}"
        target = pathlib.Path(workspace) / "output.wav"
        source.write_bytes(audio)
        result = subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", "LEI16", str(source), str(target)],
            capture_output=True, text=True, timeout=60, check=False,
        )
        if result.returncode != 0 or not target.exists():
            detail = (result.stderr or result.stdout or "").strip().splitlines()
            raise SpeechError(
                f"Could not decode '{fmt}' audio"
                + (f": {detail[-1]}" if detail else ".")
            )
        return float_samples(target.read_bytes(), "wav")


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
            loaded = await mlx_thread.run(self._load_blocking, kind)
        except (Exception, SystemExit) as exc:
            # SystemExit included deliberately: mlx-audio's phonemizer calls
            # `sys.exit` when it cannot fetch its spaCy model, and letting that
            # through unwinds the daemon rather than failing one request.
            message = str(exc) or type(exc).__name__
            self._errors[kind] = message
            log.error("failed to load %s: %s", kind.display_name, message)
            raise SpeechError(f"Could not load {kind.display_name}: {message}") from exc

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
        mlx_thread.fire_and_forget(mlx_thread.clear_cache)

    def remove(self, kind: ModelKind) -> None:
        self.stop(kind)
        self.downloader.remove(kind.model)

    # MARK: - Synthesis

    async def synthesize(
        self, text: str, voice: str | None = None, speed: float | None = None
    ) -> AsyncIterator[bytes]:
        """Streams 24 kHz 16-bit mono PCM in ~8 KB chunks, as it is produced.

        Kokoro splits long text into segments and yields each as it finishes, so
        audio is forwarded per segment rather than after the whole utterance is
        synthesized. For a paragraph that is the difference between the first word
        arriving in a second and arriving when the last one is ready — and the
        client is playing it back as it lands.
        """
        model = await self.run(ModelKind.TTS)
        chosen_voice = voice or DEFAULT_VOICE
        rate = speed or 1.0

        bridge: queue.Queue = queue.Queue(maxsize=64)
        loop = asyncio.get_running_loop()
        spoken = 0

        async with self._lock:
            pending = mlx_thread.submit(
                mlx_thread.drain_to_queue,
                lambda: self._synthesize_segments(model, text, chosen_voice, rate),
                bridge,
                _SYNTHESIS_DONE,
            )
            buffer = bytearray()
            try:
                while True:
                    item = await loop.run_in_executor(None, bridge.get)
                    if item is _SYNTHESIS_DONE:
                        break
                    if isinstance(item, BaseException):
                        raise item
                    buffer += item
                    spoken += len(item)
                    while len(buffer) >= CHUNK_BYTES:
                        yield bytes(buffer[:CHUNK_BYTES])
                        del buffer[:CHUNK_BYTES]
                if buffer:
                    yield bytes(buffer)
            finally:
                # The MLX worker is shared; a half-drained synthesis would leave the
                # next request reading someone else's audio.
                await asyncio.wrap_future(pending)

        if spoken == 0:
            log.error(
                "%s produced no audio: voice=%s speed=%s chars=%d text=%r",
                ModelKind.TTS.model_name, chosen_voice, rate, len(text), text[:200],
            )
            raise SpeechError(
                f"{ModelKind.TTS.model_name} had nothing to say for that input."
            )

    @staticmethod
    def _synthesize_segments(model, text: str, voice: str, speed: float):
        """Yields PCM for each segment Kokoro finishes. Runs on the MLX thread."""
        for result in model.generate(text=text, voice=voice, speed=speed):
            audio = getattr(result, "audio", result)
            samples = np.asarray(audio, dtype=np.float32).reshape(-1)
            if samples.size:
                yield pcm16(samples)

    # MARK: - Transcription

    async def transcribe(self, audio: bytes, audio_format: str = "wav") -> tuple[str, str | None]:
        model = await self.run(ModelKind.STT)
        samples, rate = float_samples(audio, audio_format)
        if samples.size == 0:
            raise SpeechError("Audio contained no samples.")

        target = self._transcribe_rate(model)
        samples = resample(samples, rate, target)

        async with self._lock:
            result = await mlx_thread.run(self._transcribe_blocking, model, samples)

        text = getattr(result, "text", None)
        if text is None:
            text = str(result)
        language = getattr(result, "language", None)
        return text.strip(), language

    @staticmethod
    def _transcribe_rate(model) -> int:
        """The rate the model expects raw samples to be in."""
        config = getattr(model, "preprocessor_config", None)
        return int(getattr(config, "sample_rate", 16_000) or 16_000)

    @staticmethod
    def _transcribe_blocking(model, samples: np.ndarray):
        """Parakeet takes an `mx.array`, not a numpy one.

        Handed numpy it tries to cast with `dtype=mx.bfloat16` and fails with
        "Cannot interpret 'mlx.core.bfloat16' as a data type".
        """
        import mlx.core as mx

        return model.generate(mx.array(samples))
