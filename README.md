# BigBro

A macOS menu bar app that turns your Mac into a local AI inference server for nearby iOS devices.

BigBro advertises itself on the local network via Bonjour, accepts pairing requests from iOS apps with manual per-device approval, and proxies inference requests to a local [Ollama](https://ollama.ai) instance. It fully covers both the `/api/chat` endpoint (streaming, tool calling, images, format, options) and `/api/generate`.

## How it works

1. BigBro runs in the menu bar and listens for connections on port 8765 (TCP)
2. An iOS app using [BigBroKit](https://github.com/nagata-inc/bigbro-kit) discovers your Mac via Bonjour (`_bigbro._tcp.`)
3. The iOS app sends a pairing request — an approval dialog appears on the Mac
4. Once approved, the Mac remembers the device permanently; future reconnects are auto-approved silently
5. Each inference request from iOS is forwarded to your local Ollama instance and streamed back in real time

## Requirements

- macOS 13 or later
- [Ollama](https://ollama.ai) running locally

## Installation

Download the latest release from the [Releases](../../releases) page and move BigBro.app to your Applications folder.

## Menu bar

Click the BigBro icon to see each paired device with a live status indicator and, for connected devices, the required models declared by their app — with a green checkmark if installed in Ollama or a red X if missing.

## Settings

Open **Settings** (⌘,) for two tabs:

**General** — Ollama configuration:
- **Ollama status** — live indicator showing whether Ollama is running, with an expandable list of installed models
- **Default model** — fallback model used when the iOS client doesn't specify one; populated from Ollama's installed models

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
| `request` | `requestId`, `messages`, `streaming`, `tools?`, `model?`, `format?`, `options?`, `think?`, `keep_alive?` | Chat request (`/api/chat`) |
| `generateRequest` | `requestId`, `prompt`, `streaming`, `images?`, `suffix?`, `system?`, `template?`, `model?`, `format?`, `options?`, `raw?`, `think?`, `keep_alive?` | Generate request (`/api/generate`) |
| `bye` | — | Clean disconnect |

### Mac → iOS messages

| Type | Fields | Description |
|---|---|---|
| `helloAck` | `status` (`"approved"` / `"denied"`), `missingModels?` | Pairing result with missing model list |
| `chunk` | `requestId`, `delta` | Text delta from Ollama |
| `toolCall` | `requestId`, `calls` | Tool calls array from Ollama (`/api/chat` only) |
| `done` | `requestId` | Request complete |
| `error` | `requestId`, `message` | Inference or upstream error |
| `modelsUpdate` | `missingModels` | Pushed when Ollama's model list changes |
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
│   ├── AppSettings.swift       — default model (UserDefaults)
│   └── OllamaMonitor.swift     — polls /api/tags every 5s, publishes installed models
├── Server/
│   ├── PeerServer.swift        — TCP server (NWListener)
│   ├── BonjourAdvertiser.swift — mDNS advertisement (_bigbro._tcp.)
│   └── PairingManager.swift    — device approval, persistence, required-model tracking
├── Proxy/
│   └── InferenceProxy.swift    — Ollama HTTP proxy (/api/chat + /api/generate)
└── UI/
    ├── DeviceListView.swift     — menu bar device list with model status
    └── SettingsView.swift       — settings tabs (Ollama status + devices)
```
