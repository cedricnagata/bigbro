# BigBro

A macOS menu bar app that turns your Mac into a local AI inference server for nearby iOS devices.

BigBro advertises itself on the local network via Bonjour, accepts pairing requests from iOS apps
with manual per-device approval, and runs inference **in-process** via [MLX](https://github.com/ml-explore/mlx-swift)
and [FluidAudio](https://github.com/FluidInference/FluidAudio) — no Ollama, no LocalAI, nothing to
install or run separately. Your Mac downloads the models itself, on first use or from Settings.

## How it works

1. BigBro runs in the menu bar and listens for connections on port 8765 (TCP)
2. An iOS app using [BigBroKit](https://github.com/cedricnagata/bigbro-kit) discovers your Mac via Bonjour (`_bigbro._tcp.`)
3. The iOS app sends a pairing request — an approval dialog appears on the Mac
4. Once approved, the Mac remembers the device permanently; future reconnects are auto-approved silently
5. Each request from iOS runs directly against the models loaded in the BigBro process and streams back in real time

## Requirements

- macOS 14 Sonoma or later, Apple Silicon
- ~16 GB of RAM to keep both models resident (gpt-oss-20b MXFP4 is ~12 GB; the vision model is ~2 GB)
- Nothing else — no separate server to install or keep running

## Models

BigBro hosts exactly two fixed local models, routed automatically by request content:

| Model | Runs when… | Size |
|---|---|---|
| `gpt-oss-20b` (MXFP4, via `mlx-swift-lm`) | the request is text-only | ~12 GB |
| `Qwen2.5-VL-3B-Instruct` (4-bit) | the request includes an image | ~2 GB |

There is no model picker: which model handles a request is decided by whether any message
carries an image, not by the `model` name a client asks for. Legacy Ollama-style names
(`gpt-oss:20b`, `qwen3-vl:30b`) still work for the missing-model handshake — they're mapped onto
one of the two models by a simple heuristic ("does the name mention vision") rather than matched
exactly, since BigBro no longer has models by those literal names.

Both models can stay loaded in memory at once; loading one never evicts the other.

Tool calling runs through gpt-oss's [harmony response format](https://cookbook.openai.com/articles/openai-harmony) —
BigBro parses the `analysis`/`final`/`commentary` channels out of the raw token stream itself,
since neither `mlx-swift-lm`'s built-in tool-call parsers nor the `GPTOSSModel` implementation
understand gpt-oss's channel format natively.

## Speech

Text-to-speech (Kokoro) and speech-to-text (Parakeet) run in-process via
[FluidAudio](https://github.com/FluidInference/FluidAudio) on CoreML/Neural Engine — again, no
separate server. Off by default; enabling it in Settings triggers loading both models.

Synthesized audio is always 24 kHz 16-bit mono PCM — the only format Kokoro produces, and what
BigBroKit's `BigBroAudioPlayer` expects.

## Installation

Download the latest release from the [Releases](../../releases) page and move BigBro.app to your Applications folder.

## Menu bar

Click the BigBro icon to see each paired device with a live status indicator and, for connected
devices, the required models declared by their app, mapped onto whichever local model satisfies
them.

## Settings

Open **Settings** (⌘,) for two tabs:

**General**
- **Models** — one row per fixed local model: not downloaded / downloading (%) / loaded, with a
  **Download** button
- **Speech** — off by default; when enabled, shows load status, a free-form Kokoro voice field
  (e.g. `af_heart`), and **Preview**

**Devices** — paired device management:
- Each connected device shows its required models, each mapped to the local model that satisfies it, with install status (✓ / ✗)
- **Disconnect** — closes the current connection (device stays remembered, will auto-reconnect)
- **Remove** — forgets the device entirely; it will need to re-pair with approval
- **Refresh** — pings all live connections; dead ones flip to disconnected
- **Remove All** — forgets every paired device

## Required models

iOS apps built with BigBroKit can declare which models they require. On connect, BigBro:

1. Reports missing models back to the iOS app in the `helloAck` response, mapped onto the local model each name refers to
2. Shows a notification on the Mac listing any models that need to be downloaded
3. Pushes live updates to connected devices as local models finish downloading

If an inference request arrives before the model it needs is downloaded, BigBro starts the
download and tells the client, rather than generating anything.

## TCP protocol

BigBro uses a custom framed TCP protocol on port 8765. Each message is a 4-byte big-endian length
prefix followed by a UTF-8 JSON object. **This is unchanged from BigBro's Ollama-proxy days** —
existing BigBroKit clients work against this branch without a rebuild.

### iOS → Mac messages

| Type | Fields | Description |
|---|---|---|
| `hello` | `deviceId`, `deviceName`, `appName`, `requiredModels?` | Initiate pairing |
| `request` | `requestId`, `messages`, `streaming`, `tools?`, `model?`, `options?` | Chat request |
| `generateRequest` | `requestId`, `prompt`, `streaming`, `images?`, `system?`, `model?`, `options?` | Single-turn generate |
| `speechRequest` | `requestId`, `input`, `voice?`, `speed?` | Text-to-speech |
| `transcribeRequest` | `requestId`, `audio` (base64), `audioFormat?` | Speech-to-text. Max 10 MB decoded |
| `bye` | — | Clean disconnect |

Routing is decided by request content (images present → vision model), not by the `model` field.
`format` (JSON-schema-constrained output), `think` (reasoning effort) and `keep_alive` are
accepted for wire compatibility but currently have no effect — gpt-oss always reasons via its
harmony `analysis` channel, and both models stay resident regardless of idle time.

### Mac → iOS messages

| Type | Fields | Description |
|---|---|---|
| `helloAck` | `status` (`"approved"` / `"denied"`), `missingModels?` | Pairing result with missing model list |
| `chunk` | `requestId`, `delta` | Assistant text delta (harmony `final` channel) |
| `thinking` | `requestId`, `delta` | Reasoning delta (harmony `analysis` channel), kept separate from `chunk` so it is never spoken or shown as an answer |
| `toolCall` | `requestId`, `calls` | Tool calls array (`request` only) |
| `audioStart` | `requestId`, `format`, `sampleRate`, `channels`, `voice` | Precedes audio, so playback can be configured before the first chunk. Always `pcm`/24000/1 |
| `audioChunk` | `requestId`, `audio` (base64), `seq` | Synthesized audio, ~8 KB per chunk |
| `transcript` | `requestId`, `text`, `language?` | Transcription result |
| `done` | `requestId` | Request complete |
| `error` | `requestId`, `message` | Inference error |
| `modelsUpdate` | `missingModels` | Pushed when a local model finishes downloading |
| `bye` | — | Clean disconnect |

## Building from source

Open `bigbro.xcodeproj` in Xcode, select the **bigbro** scheme, and build. Swift Package Manager
resolves `mlx-swift`, `mlx-swift-lm` and `FluidAudio` automatically.

Required entitlements (already configured in the project):
- `com.apple.security.network.server`
- `com.apple.security.network.client`

## Source layout

```
bigbro/
├── App/
│   ├── bigbroApp.swift         — app entry, AppModel, AppRouter
│   ├── AppSettings.swift       — speech toggle + voice (UserDefaults)
│   ├── BackendStatus.swift     — BackendStatus enum, BackendStatusReporting protocol
│   ├── ModelInstalling.swift   — install protocol (ModelInstallProgress)
│   └── ModelDownloader.swift   — coordinates installs, publishes throttled progress
├── Inference/
│   ├── MLXEngine.swift         — loads/runs gpt-oss-20b + Qwen2.5-VL-3B via MLX, message translation
│   ├── HarmonyParser.swift     — splits gpt-oss's harmony channels out of the raw token stream
│   └── MLXInstaller.swift      — ModelInstalling conformer backed by MLXEngine.ensureLoaded
├── Speech/
│   └── SpeechEngine.swift      — Kokoro TTS + Parakeet STT via FluidAudio
├── Server/
│   ├── PeerServer.swift        — TCP server (NWListener)
│   ├── BonjourAdvertiser.swift — mDNS advertisement (_bigbro._tcp.)
│   ├── PairingManager.swift    — device approval, persistence, required-model tracking
│   └── PowerAssertion.swift    — keeps the Mac awake while peers are connected
└── UI/
    ├── DeviceListView.swift     — menu bar device list with model status
    ├── BackendStatusView.swift  — reusable backend status indicator
    ├── SpeechPreview.swift      — auditions a voice locally via AVAudioPlayer
    └── SettingsView.swift       — settings tabs (models, speech, devices)
```
