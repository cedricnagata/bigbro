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
- Enough RAM for the models you run — the default pair (gpt-oss-20b MXFP4 at ~12 GB plus a ~2 GB vision model) wants ~16 GB; the smaller Llama and Gemma models need far less
- Nothing else — no separate server to install or keep running

## Models

BigBro can download and run any model in its catalog — a curated subset of `mlx-swift-lm`'s
registries. Defaults are set in Settings; a client can also name a model per request.

| Model | Tools | Reasoning | Size |
|---|---|---|---|
| gpt-oss 20B | ✓ | low / medium / high | ~12 GB |
| Qwen3 8B / 4B | ✓ | on / off | ~4.7 / 2.4 GB |
| Llama 3.1 8B, 3.2 3B, 3.2 1B | ✓ | — | ~4.5 / 1.8 / 0.7 GB |
| Gemma 4 E4B / E2B, Gemma 3 1B | — | — | ~4.4 / 3.0 / 0.8 GB |
| Phi 3.5 Mini | — | — | ~2.2 GB |
| DeepSeek-R1 Distill 7B | — | always | ~4.2 GB |
| Qwen2.5-VL 3B, Qwen3-VL 4B (vision) | — | — | ~2.0 / 2.5 GB |
| Gemma 3 4B, Gemma 4 E2B (vision) | — | — | ~3.0 GB |

Models differ in what they support, and BigBro adapts rather than refusing — see
[Capability mismatches](#capability-mismatches). Requests carrying images always run on the
vision model regardless of what was asked for, since a language model has no vision tower.

Any number of models can stay resident at once; loading one never evicts another. Nothing is
ever unloaded automatically, so a Mac that runs several large models holds them all.

Tool calling for gpt-oss runs through its [harmony response format](https://cookbook.openai.com/articles/openai-harmony) —
BigBro parses the `analysis`/`final`/`commentary` channels out of the raw token stream itself,
since neither `mlx-swift-lm`'s built-in tool-call parsers nor the `GPTOSSModel` implementation
understand gpt-oss's channel format natively. Other models use `mlx-swift-lm`'s own tool-call
parsing and their own output framing (`<think>` tags, or none at all).

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
devices, the models declared by their app, each resolved to the catalog entry that satisfies it.

## Settings

Open **Settings** (⌘,) for two tabs:

**General**
- **Defaults** — which model answers when a device doesn't name one, for text and for vision
- **Language models** / **Vision models** — one row per catalog model showing capability badges
  (tools, images, reasoning), size, and state: not downloaded / downloading (%) / loaded, with a
  **Download** button
- **Speech** — off by default; when enabled, shows one row per speech model (Kokoro, Parakeet)
  with its own download progress, plus a free-form Kokoro voice field (e.g. `af_heart`) and
  **Preview**

**Devices** — paired device management:
- Each connected device shows its required models, each resolved to the catalog entry that satisfies it, with install status (✓ / ✗)
- **Disconnect** — closes the current connection (device stays remembered, will auto-reconnect)
- **Remove** — forgets the device entirely; it will need to re-pair with approval
- **Refresh** — pings all live connections; dead ones flip to disconnected
- **Remove All** — forgets every paired device

## Required models

iOS apps built with BigBroKit can declare which models they require. On connect, BigBro:

1. Reports missing models back to the iOS app in the `helloAck` response, resolved to the catalog entry each name refers to
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
| `request` | `requestId`, `messages`, `streaming`, `tools?`, `model?`, `options?`, `think?`, `reasoning_effort?` | Chat request |
| `generateRequest` | `requestId`, `prompt`, `streaming`, `images?`, `system?`, `model?`, `options?`, `think?`, `reasoning_effort?` | Single-turn generate |
| `speechRequest` | `requestId`, `input`, `voice?`, `speed?` | Text-to-speech |
| `transcribeRequest` | `requestId`, `audio` (base64), `audioFormat?` | Speech-to-text. Max 10 MB decoded |
| `preload` | `requestId`, `model?` (a catalog id, or `"text"` / `"vision"` / `"tts"` / `"stt"` / `"speech"`, default `"text"`) | Loads a model into memory without generating anything — see below |
| `bye` | — | Clean disconnect |

`model` names a catalog entry (see below). Absent or unrecognized, the Mac's configured
default is used. Images override it either way: a language model has no vision tower, so a
request carrying images always runs on the vision model, substituting one if necessary.

`format` (JSON-schema-constrained output) and `keep_alive` are accepted for wire compatibility
but currently have no effect — loaded models stay resident regardless of idle time.

### Models

Any model in `ModelCatalog` can be downloaded and run, picked per request or set as a default
in Settings. The catalog is a curated subset of mlx-swift-lm's registries rather than all of
it, because each entry carries three hand-verified facts that cannot be derived from the
registry — and a wrong value corrupts responses rather than failing:

| Fact | Why it can't be guessed |
|---|---|
| Tool support | Whether the chat template has a tools slot at all. Gemma and Phi don't. |
| Reasoning style | None (Gemma, Llama), harmony channels (gpt-oss), or `<think>` tags (Qwen3, DeepSeek-R1). |
| Effort control | `reasoning_effort` is harmony-only; Qwen3's lever is `enable_thinking`, a different key. |

Adding a model means adding an entry and checking those three fields.

### Capability mismatches

A request can ask for more than the chosen model can do. Rather than refusing, BigBro adapts
and says what it did — a refusal would be worse, since the model can usually still answer:

- **Tools** on a model without them are removed before templating. Passing them anyway either
  throws in the template or drops them silently, and neither tells the caller anything.
- **`reasoning_effort`** on a non-harmony model is dropped. Jinja ignores unknown variables, so
  left in it would look like it worked while doing nothing.
- **Images** on a language model substitute the vision model. Answering from the text alone
  would be worse than switching, since the image never reaches the prompt at all.

Each of these sends a `modelCapabilities` message before the answer, carrying the model's real
capabilities and a human-readable note per adaptation. BigBroKit exposes it as
`client.modelNotes`. Clients that predate the message ignore it.

Output framing is chosen per model too. The harmony parser withholds text until it sees channel
markers, so running it over a Gemma response would swallow the opening of every reply — each
reasoning style gets its own parser (`ResponseParser`).

### Reasoning: `think` vs `reasoning_effort`

Two separate knobs, and the difference matters:

| Field | What it changes | Where it acts |
|---|---|---|
| `think` (default on) | Whether reasoning tokens are sent to the client as `thinking` messages | After generation — pure wire filtering in `AppRouter` |
| `reasoning_effort` | How long the model spends in its `analysis` channel before reaching the final one | Before generation — passed to the chat template as `additionalContext` |

gpt-oss computes its harmony `analysis` channel either way, so `think` alone changes what the
client sees, not what the model does or how long it takes. `reasoning_effort` is the one that
actually shortens the work.

Valid values are **`low`, `medium`, `high`** — nothing else. The Harmony template renders the
value literally into the system message as `Reasoning: <level>`, and gpt-oss was trained on
exactly those three words, so there is no "off": a fourth value would land in the prompt as
text the model has never seen, degrading the answer rather than skipping the analysis. `low`
is as close to off as gpt-oss gets. Unrecognized values are dropped and the template default
(`medium`) applies.

When `reasoning_effort` is absent, `think: false` is read as a request for speed and lowers
the budget to `low` — preserving what that flag did on its own before clients could name a
level. An explicit `reasoning_effort` always wins over that inference.

### Preloading a model

Loading a model — reading its weights off disk and materializing them into MLX arrays — is a
real, multi-second cost that BigBro only pays lazily, the first time a request actually needs
that model. That cost otherwise lands on whichever message happens to be first. Send `preload`
when a chat session is likely to start soon (e.g. when the chat screen appears) to move it
earlier instead:

- If the model is already downloaded, BigBro loads it into memory and replies with `done`
  once it's ready to use — nothing is generated.
- If it isn't downloaded yet, this triggers the same `modelDownloading` flow a real request
  would.

BigBroKit exposes this as `BigBroClient.preloadModel(vision:)`. It's a pure optimization —
skipping it is harmless, since `request`/`generateRequest` load the model themselves anyway if
it isn't already resident.

`"tts"`, `"stt"` and `"speech"` (both) warm Kokoro and Parakeet instead, via
`BigBroClient.preloadSpeech()`. BigBro already loads these at launch whenever speech is
enabled, so this is usually instant — its real job is giving a client somewhere to *wait*.
That matters for a hands-free voice loop, where a cold model load would otherwise swallow the
first thing the user says. Errors if speech is switched off in Settings.

### Spoken conversation

There is no server-side voice mode: an end-to-end spoken turn is `transcribeRequest` →
`request` → `speechRequest`, driven from the client. That is deliberate — the tool-calling
loop runs on the device, so only the client knows which model turn is a final answer worth
speaking and which is an intermediate tool step. BigBroKit packages the sequence as
`BigBroClient.converse(audio:)` and the continuous version as `BigBroVoiceSession`.

### Mac → iOS messages

| Type | Fields | Description |
|---|---|---|
| `helloAck` | `status` (`"approved"` / `"denied"`), `missingModels?` | Pairing result with missing model list |
| `chunk` | `requestId`, `delta` | Assistant text delta |
| `thinking` | `requestId`, `delta` | Reasoning delta, kept separate from `chunk` so it is never spoken or shown as an answer. Only from models that reason |
| `modelCapabilities` | `requestId`, `model`, `supportsTools`, `supportsImages`, `supportsReasoning`, `supportsReasoningEffort`, `notes` | Sent before the answer when the chosen model couldn't do everything asked — see Capability mismatches |
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
│   ├── AppSettings.swift       — default model ids, speech toggle + voice (UserDefaults)
│   ├── BackendStatus.swift     — BackendStatus enum, BackendStatusReporting protocol
│   ├── ModelInstalling.swift   — install protocol (ModelInstallProgress)
│   └── ModelDownloader.swift   — coordinates installs, publishes throttled progress
├── Inference/
│   ├── ModelCatalog.swift      — the supported models and their hand-verified capabilities
│   ├── MLXEngine.swift         — loads/runs catalog models via MLX, capability negotiation, message translation
│   ├── ResponseParser.swift    — per-model output framing: harmony channels, <think> tags, or plain
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
    ├── SpeechPreview.swift      — auditions a voice locally via AVAudioPlayer
    └── SettingsView.swift       — settings tabs (model defaults + catalog, speech models, devices)
```
