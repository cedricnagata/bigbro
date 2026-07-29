# BigBro

A macOS menu bar app that turns your Mac into a local AI inference server for nearby iOS devices.

BigBro advertises itself on the local network via Bonjour, accepts pairing requests from iOS apps with manual per-device approval, and proxies inference requests to a local backend over the **OpenAI-compatible API** (`/v1/chat/completions`) — streaming, tool calling, images, structured output and model options.

Targeting the OpenAI surface rather than any one backend's native API means [Ollama](https://ollama.ai), [LocalAI](https://localai.io), Speaches, vLLM, LM Studio and llama.cpp-server are all interchangeable: switching backends is a base-URL change, not a code change.

## How it works

1. BigBro runs in the menu bar and listens for connections on port 8765 (TCP)
2. An iOS app using [BigBroKit](https://github.com/nagata-inc/bigbro-kit) discovers your Mac via Bonjour (`_bigbro._tcp.`)
3. The iOS app sends a pairing request — an approval dialog appears on the Mac
4. Once approved, the Mac remembers the device permanently; future reconnects are auto-approved silently
5. Each request from iOS is forwarded to your local backend over `/v1/…` and streamed back in real time

## Requirements

- macOS 14 Sonoma or later
- [Ollama](https://ollama.ai) running locally for text generation
- Optional: a speech backend for text-to-speech and transcription (see below)

## Backends

BigBro speaks the OpenAI-compatible API, so any server exposing `/v1/…` works. Capabilities
differ, which is why chat and speech are configured separately:

| | Ollama (`:11434`) | LocalAI (`:8080`) | Speaches (`:8000`) |
|---|---|---|---|
| `/v1/chat/completions` | ✅ | ✅ | — |
| `tools` / tool calling | ✅ | ✅ | — |
| `/v1/audio/speech` | ❌ | ✅ | ✅ |
| `/v1/audio/transcriptions` | ❌ | ✅ | ✅ |
| Model install from BigBro | ✅ `/api/pull` | ✅ gallery | — |

Ollama has no audio endpoints and no plans to add them — the native-TTS proposal
([#11021](https://github.com/ollama/ollama/issues/11021)) was closed as a duplicate of
[#5424](https://github.com/ollama/ollama/issues/5424), open since 2024 — so speech needs a
second server.

### Speech backend setup

**LocalAI** (default, `http://localhost:8080`) serves both speech and transcription:

```sh
docker run -p 8080:8080 --name localai localai/localai:latest
```

A native macOS DMG exists but has [known installer problems on Apple Silicon](https://github.com/mudler/LocalAI/issues/6679);
Docker or the plain binary avoid them.

**Speaches** (`http://localhost:8000`) is a drop-in alternative — Kokoro or Piper for speech,
faster-whisper for transcription — and describes itself as "Ollama, but for TTS/STT".

Enable speech in **Settings → Speech**, then use **Preview** to confirm a voice works before
involving a device.

## Installation

Download the latest release from the [Releases](../../releases) page and move BigBro.app to your Applications folder.

## Menu bar

Click the BigBro icon to see each paired device with a live status indicator and, for connected devices, the required models declared by their app — with a green checkmark if installed in Ollama or a red X if missing.

## Settings

Open **Settings** (⌘,) for two tabs:

**General** — backend configuration, in two sections:

*Text Generation*
- **Status** — live indicator for the chat backend, with an expandable list of installed models
- **Default model** — fallback used when the iOS client doesn't specify one

*Speech* — off by default, and while off nothing is polled and no warnings appear
- **Enable speech** — turns text-to-speech and transcription on
- **Status** — live indicator for the speech backend, with the voices it reports
- **Voice** — free-form, since voice names aren't standardised across backends (`af_heart`, `alloy`, `en_US-amy-medium`); the menu lists whatever the backend advertises, and **Preview** plays a sample on the Mac
- **Speech model** / **Audio format** / **Transcription model**

**Devices** — paired device management:
- Each connected device shows its required models with install status (✓ installed / ✗ missing)
- **Disconnect** — closes the current connection (device stays remembered, will auto-reconnect)
- **Remove** — forgets the device entirely; it will need to re-pair with approval
- **Refresh** — pings all live connections; dead ones flip to disconnected
- **Remove All** — forgets every paired device

## Required models

iOS apps built with BigBroKit can declare which Ollama models they require. On connect, BigBro:

1. Reports missing models back to the iOS app in the `helloAck` response
2. Shows a notification on the Mac listing any models that need to be downloaded in Ollama
3. Pushes live updates to connected devices as Ollama's model list changes

If an inference request arrives for a model that isn't installed, BigBro returns an error response rather than forwarding to Ollama.

## TCP protocol

BigBro uses a custom framed TCP protocol on port 8765. Each message is a 4-byte big-endian length prefix followed by a UTF-8 JSON object.

### iOS → Mac messages

| Type | Fields | Description |
|---|---|---|
| `hello` | `deviceId`, `deviceName`, `appName`, `requiredModels?` | Initiate pairing |
| `request` | `requestId`, `messages`, `streaming`, `tools?`, `model?`, `format?`, `options?`, `think?`, `keep_alive?` | Chat request → `/v1/chat/completions` |
| `generateRequest` | `requestId`, `prompt`, `streaming`, `images?`, `suffix?`, `system?`, `template?`, `model?`, `format?`, `options?`, `raw?`, `think?`, `keep_alive?` | Single-turn generate → `/v1/chat/completions` |
| `speechRequest` | `requestId`, `input`, `voice?`, `model?`, `response_format?`, `speed?` | Text-to-speech → `/v1/audio/speech` |
| `transcribeRequest` | `requestId`, `audio` (base64), `audioFormat?`, `model?`, `language?` | Speech-to-text → `/v1/audio/transcriptions`. Max 10 MB decoded |
| `bye` | — | Clean disconnect |

The wire format is unchanged from BigBro's Ollama-native days — the Mac translates it. `think` maps to `reasoning_effort`, `format` to `response_format`, `options` to their OpenAI equivalents, and message images to content parts. `template`, `raw` and `suffix` have no chat-completions equivalent and return an `error` rather than being silently dropped.

### Mac → iOS messages

| Type | Fields | Description |
|---|---|---|
| `helloAck` | `status` (`"approved"` / `"denied"`), `missingModels?` | Pairing result with missing model list |
| `chunk` | `requestId`, `delta` | Assistant text delta |
| `thinking` | `requestId`, `delta` | Reasoning delta, kept separate from `chunk` so it is never spoken or shown as an answer |
| `toolCall` | `requestId`, `calls` | Tool calls array (`request` only) |
| `audioStart` | `requestId`, `format`, `sampleRate`, `channels`, `model`, `voice` | Precedes audio, so playback can be configured before the first chunk |
| `audioChunk` | `requestId`, `audio` (base64), `seq` | Synthesized audio, ~8 KB per chunk |
| `transcript` | `requestId`, `text`, `language?` | Transcription result |
| `done` | `requestId` | Request complete |
| `error` | `requestId`, `message` | Inference or upstream error |
| `modelsUpdate` | `missingModels` | Pushed when the backend's model list changes |
| `bye` | — | Clean disconnect |

## Building from source

Open `bigbro.xcodeproj` in Xcode, select the **bigbro** scheme, and build.

Required entitlements (already configured in the project):
- `com.apple.security.network.server`
- `com.apple.security.network.client`

## Source layout

```
bigbro/
├── App/
│   ├── bigbroApp.swift         — app entry, AppModel, AppRouter
│   ├── AppSettings.swift       — backend URLs + default model (UserDefaults)
│   ├── BackendStatus.swift     — BackendStatus enum, BackendStatusReporting protocol
│   ├── OllamaMonitor.swift     — polls the chat backend every 5s, publishes models
│   ├── SpeechMonitor.swift     — polls the speech backend, publishes voices
│   ├── ModelInstalling.swift   — install protocol + Ollama and LocalAI implementations
│   └── ModelDownloader.swift   — coordinates installs, publishes throttled progress
├── Server/
│   ├── PeerServer.swift        — TCP server (NWListener)
│   ├── BonjourAdvertiser.swift — mDNS advertisement (_bigbro._tcp.)
│   ├── PairingManager.swift    — device approval, persistence, required-model tracking
│   └── PowerAssertion.swift    — keeps the Mac awake while peers are connected
├── Proxy/
│   ├── OpenAIProxy.swift       — chat (SSE), speech, transcription
│   └── MultipartBody.swift     — multipart writer for /v1/audio/transcriptions
└── UI/
    ├── DeviceListView.swift     — menu bar device list with model status
    ├── BackendStatusView.swift  — reusable backend status indicator
    ├── SpeechPreview.swift      — auditions a voice locally via AVAudioPlayer
    └── SettingsView.swift       — settings tabs (backends + devices)
```
