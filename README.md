# BigBro

A macOS menu bar app that turns your Mac into a local AI inference server for nearby iOS devices.

BigBro advertises itself on the local network, accepts pairing requests from iOS apps with manual approval, remembers approved devices across restarts, and proxies chat requests to a local LLM backend (Ollama, LM Studio, or any OpenAI-compatible server).

## How it works

1. BigBro runs in your menu bar and listens on port 8765
2. An iOS app using [BigBroKit](https://github.com/nagata-inc/bigbro-kit) discovers your Mac via Bonjour
3. The iOS app sends a pairing request — a dialog appears on your Mac to approve or deny it
4. Once paired, the Mac remembers the device; future reconnects from the same iOS device are auto-approved silently
5. A long-lived Server-Sent Events stream (`/presence`) keeps both sides' UIs in sync: when iOS connects, the menu bar row turns green; when the stream drops for any reason, both sides flip to disconnected within 15 seconds

## Requirements

- macOS 13 or later
- A local LLM backend running on the same Mac (e.g. [Ollama](https://ollama.ai), [LM Studio](https://lmstudio.ai))

## Installation

Download the latest release from the [Releases](../../releases) page and move BigBro.app to your Applications folder.

## Menu bar

Click the BigBro icon in the menu bar to see each paired device with a live status indicator:

- 🟢 Connected
- ⚪️ Disconnected

## Settings

Cmd+, or **Settings** from the menu bar opens a tabbed window:

**General** — inference backend configuration:
- **Server URL** — base URL of your local inference server (default: `http://localhost:11434`)
- **Default model** — fallback model name when the iOS client doesn't specify one (default: `gpt-oss-20b`)

**Devices** — paired device management:
- Per-device **Disconnect** closes the current connection (the device stays remembered and will auto-reconnect next time it reaches out)
- Per-device **Remove** fully forgets the device; it will need to re-pair with approval
- **Refresh** pokes every live stream with an immediate ping — dead connections fail the TCP write and flip to disconnected, healthy connections stay up
- **Remove All** forgets every paired device

## HTTP API

BigBro exposes a local HTTP API on port 8765. iOS clients using BigBroKit interact with this automatically.

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/pair/request` | POST | none | Request pairing; body: `{"device_name": "...", "device_id": "..."}` |
| `/pair/status` | GET | none | Poll status; query: `?device_id=...` |
| `/presence` | GET | token | Long-lived SSE stream; Mac pings every 10s, iOS treats 15s silence as dead |
| `/chat` | POST | token | Send a chat message; body: `{"token": "...", "messages": [...]}` |

Chat responses are streamed as Server-Sent Events:
```
data: {"delta":"Hello"}

data: {"delta":" world"}

data: [DONE]
```

## Building from source

Open `bigbro.xcworkspace` (or `bigbro/bigbro.xcodeproj`) in Xcode, select the **bigbro** scheme, and build.

Requires the following entitlements (already configured):
- `com.apple.security.network.server`
- `com.apple.security.network.client`
