# BigBro

A macOS menu bar app that turns your Mac into a local AI inference server for nearby iOS devices.

BigBro advertises itself on the local network, accepts pairing requests from iOS apps with manual approval, and proxies chat requests to a local LLM backend (Ollama, LM Studio, or any OpenAI-compatible server).

## How it works

1. BigBro runs in your menu bar and listens on port 8765
2. An iOS app using [BigBroKit](https://github.com/nagata-inc/bigbro-kit) discovers your Mac via Bonjour
3. The iOS app sends a pairing request — a dialog appears on your Mac to approve or deny it
4. Once paired, the iOS app can send chat messages through your Mac to whatever LLM backend you have running locally

## Requirements

- macOS 13 or later
- A local LLM backend running on the same Mac (e.g. [Ollama](https://ollama.ai), [LM Studio](https://lmstudio.ai))

## Installation

Download the latest release from the [Releases](../../releases) page and move BigBro.app to your Applications folder.

## Configuration

Click the brain icon in the menu bar → **Settings** to configure:

- **Backend URL** — the base URL of your local inference server (default: `http://localhost:11434`)
- **Default model** — the model name to use when none is specified by the client (default: `gpt-oss-20b`)

## HTTP API

BigBro exposes a local HTTP API on port 8765. iOS clients using BigBroKit interact with this automatically.

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/pair/request` | POST | none | Request pairing; body: `{"device_name": "...", "device_id": "..."}` |
| `/pair/status` | GET | none | Poll status; query: `?device_id=...` |
| `/chat` | POST | token | Send a chat message; body: `{"token": "...", "messages": [...]}` |

Chat responses are streamed as Server-Sent Events:
```
data: {"delta":"Hello"}

data: {"delta":" world"}

data: [DONE]
```

## Building from source

Open `BigBro.xcodeproj` in Xcode, select the **bigbro** scheme, and build.

Requires the following entitlements (already configured):
- `com.apple.security.network.server`
- `com.apple.security.network.client`
