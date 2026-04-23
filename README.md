# BigBro

A macOS menu bar app that turns your Mac into a local AI inference server for nearby iOS devices.

BigBro advertises itself on the local network via Bonjour, accepts pairing requests from iOS apps with manual per-device approval, and proxies inference requests to a local [Ollama](https://ollama.ai) instance. It fully covers both the `/api/chat` endpoint (streaming, tool calling, images, format, options) and `/api/generate`.

## How it works

1. BigBro runs in the menu bar and listens for connections on port 8765 (TCP)
2. An iOS app using [BigBroKit](https://github.com/nagata-inc/bigbro-kit) discovers your Mac via Bonjour (`_bigbro._tcp.`)
3. The iOS app sends a pairing request — an approval dialog appears on the Mac
4. Once approved, the Mac remembers the device permanently; future reconnects from that device are auto-approved silently
5. Each inference request from iOS is forwarded to your local Ollama instance and streamed back in real time
6. A heartbeat (ping/pong every 10 seconds) detects dead connections; both sides flip to disconnected within 25 seconds of silence

## Requirements

- macOS 13 or later
- [Ollama](https://ollama.ai) running on the same Mac (or any OpenAI-compatible server at a reachable URL)

## Installation

Download the latest release from the [Releases](../../releases) page and move BigBro.app to your Applications folder.

## Menu bar

Click the BigBro icon to see each paired device with a live status indicator:

- Green dot — Connected
- Grey dot — Disconnected

## Settings

Open **Settings** (⌘,) for two tabs:

**General** — Ollama configuration:
- **Server URL** — base URL of your Ollama server (default: `http://localhost:11434`)
- **Default model** — fallback model name when the iOS client doesn't specify one (default: `gpt-oss-20b`)

**Devices** — paired device management:
- **Disconnect** — closes the current connection (device stays remembered, will auto-reconnect)
- **Remove** — forgets the device entirely; it will need to re-pair with approval
- **Refresh** — pings all live connections; dead ones flip to disconnected
- **Remove All** — forgets every paired device

## TCP protocol

BigBro uses a custom framed TCP protocol on port 8765. Each message is a 4-byte big-endian length prefix followed by a UTF-8 JSON object.

### iOS → Mac messages

| Type | Fields | Description |
|---|---|---|
| `hello` | `deviceId`, `deviceName` | Initiate pairing |
| `request` | `requestId`, `messages`, `streaming`, `tools?`, `model?`, `format?`, `options?`, `think?`, `keep_alive?` | Chat request (`/api/chat`) |
| `generateRequest` | `requestId`, `prompt`, `streaming`, `images?`, `suffix?`, `system?`, `template?`, `model?`, `format?`, `options?`, `raw?`, `think?`, `keep_alive?` | Generate request (`/api/generate`) |
| `ping` | — | Heartbeat |
| `bye` | — | Clean disconnect |

### Mac → iOS messages

| Type | Fields | Description |
|---|---|---|
| `helloAck` | `status` (`"approved"` / `"denied"`) | Pairing result |
| `chunk` | `requestId`, `delta` | Text delta from Ollama |
| `toolCall` | `requestId`, `calls` | Tool calls array from Ollama (`/api/chat` only) |
| `done` | `requestId` | Request complete |
| `error` | `requestId`, `message` | Inference or upstream error |
| `pong` | — | Heartbeat reply |
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
│   └── AppSettings.swift       — Ollama URL + model (UserDefaults)
├── Server/
│   ├── PeerServer.swift        — TCP server (NWListener)
│   ├── BonjourAdvertiser.swift — mDNS advertisement
│   └── PairingManager.swift    — device approval + persistence
├── Proxy/
│   └── InferenceProxy.swift    — Ollama HTTP proxy (/api/chat + /api/generate)
└── UI/
    ├── DeviceListView.swift     — menu bar device list
    └── SettingsView.swift       — settings tabs
```
