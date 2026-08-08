# BigBro

A macOS app that turns your Mac into a local AI inference server for nearby iOS devices.

BigBro advertises itself on the local network via Bonjour, accepts pairing requests from iOS apps
with explicit per-device approval, and runs inference **in-process** via
[mlx-lm](https://github.com/ml-explore/mlx-lm) / [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) and
[mlx-audio](https://github.com/Blaizzy/mlx-audio) — no Ollama, no LocalAI, nothing to install or
run separately. Your Mac downloads the models itself, on first use or from the CLI.

## How it works

1. `bigbro serve` listens for connections on port 8765 (TCP) and holds the Mac awake while it runs
2. An iOS app using [BigBroKit](https://github.com/cedricnagata/bigbro-kit) discovers your Mac via Bonjour (`_bigbro._tcp.`)
3. The iOS app sends a pairing request — a prompt appears in the dashboard and the daemon waits
4. You hit Enter (or run `bigbro pair approve <id>`); the Mac then remembers the device permanently and future reconnects are auto-approved silently
5. Each request from iOS runs directly against the models loaded in the BigBro process and streams back in real time

## Requirements

- macOS 14 Sonoma or later, Apple Silicon
- Python 3.10–3.13, **only if you install the CLI with uv** — the app carries its own. The ceiling
  is spaCy, which reaches this project through `mlx-audio` → `misaki` and publishes no `cp314`
  wheels yet
- Enough RAM for the models you run — a large pairing (gpt-oss-20b MXFP4 at ~12 GB plus a ~2 GB
  vision model) wants ~16 GB; the smaller Llama and Gemma models need far less
- Nothing else — no separate server to install or keep running

## Installation

Download the latest `BigBro-<version>-arm64.dmg` from
[Releases](https://github.com/cedricnagata/bigbro/releases), open it, and drag BigBro to
Applications. That is the whole thing — there is no Python to install, no `uv`, no terminal.

The download is around 600 MB and expands to roughly 1.3 GB, because the app carries its own
interpreter and its own copy of the MLX stack. Model weights are *not* included; BigBro downloads
those on first use, into the usual `~/.cache/huggingface`.

**On first launch macOS will ask for Local Network access. Say yes.** BigBro advertises itself over
Bonjour so nearby iPhones can find your Mac, and that is exactly what the prompt governs. If you
decline, the app runs and the daemon serves, but no iOS device will ever discover it — and nothing
in the log will explain why. You can change your mind in System Settings › Privacy & Security ›
Local Network.

### Just the CLI

If you only want `bigbro` in a terminal — a headless Mac mini, CI, a machine you never sit at —
install it with [uv](https://docs.astral.sh/uv/) instead:

```sh
uv tool install git+https://github.com/cedricnagata/bigbro
```

That puts `bigbro` on your PATH with its own interpreter and its own copy of the MLX stack. Pin a
release with `@v1.0.0`, or track the tip by re-running with `--force`. Expect around 1.4 GB.

If you installed the app, you do not need this: BigBro can install the same `bigbro` command into
`~/.local/bin` for you, pointing at the interpreter it already carries. Settings › Command line.

> **BigBro is not on an index, and the two installs above are the supported ones.** The name on
> PyPI belongs to an unrelated project, so `pip install bigbro` gets you someone else's package and
> no `bigbro` command. Building a wheel from this repo and installing *that* also fails — Kokoro's
> phonemizer needs a spaCy model, spaCy models are not published to PyPI, and the URL that resolves
> it lives in `[tool.uv.sources]`, which uv reads from the project rather than carrying into a
> built artifact. Installing from git keeps that table in play, which is why it works — and it is
> also why the DMG is built by syncing the project rather than by building a wheel.

BigBro requires Python 3.10 to 3.13. The ceiling is the macOS dependency chain rather than the
code: `mlx-audio` pulls in `misaki`, which pulls in spaCy, which publishes wheels only up to
`cp313`. Because `requires-python` declares that, uv will pick a compatible interpreter for you
even if your default is newer — you do not have to name one. The app is unaffected either way; it
carries 3.12 inside it.

### Working on it

For development, install from a clone so edits take effect without reinstalling:

```sh
git clone https://github.com/cedricnagata/bigbro
uv tool install --editable ./bigbro
```

`--editable` is deliberate: it links the tool to the working copy, so an edit to the source takes
effect the next time you run `bigbro` with nothing to reinstall. Without it, `uv tool install
--force` will happily serve a **cached build** of the previous source — the command reports
success, the old code keeps running, and the only symptom is a fix that appears not to work. If
you do want a non-editable install, `uv cache clean bigbro && uv tool install --force --reinstall .`
is what actually rebuilds.

A plain `pip install -e .` from a clone does work, but installs into whichever Python is active —
and the MLX stack pulls recent `transformers`, `huggingface-hub`, `tokenizers`, `pydantic`,
`fastapi` and `starlette`, which it will upgrade for every other project sharing that interpreter.
Use a venv if you go that way; see [Development](#development).

### Working on the app

```sh
brew install xcodegen        # once
uv sync --extra dev          # once — gives you .venv/bin/bigbro
app/Scripts/dev.sh           # generates BigBro.xcodeproj and opens it
```

Then ⌘R. `BigBro.xcodeproj` is **generated from `app/project.yml` and gitignored** — a `.pbxproj`
is merge-hostile and unreadable in review, and the spec that produces it is forty lines you can
actually diff. Editing the project in Xcode's inspector works until the next `xcodegen`, so change
`project.yml` instead. Re-run `dev.sh` after adding a source file, since a new file only joins the
project when the spec is re-read.

The scheme sets `BIGBRO_DAEMON_COMMAND` to the project's own venv, so ⌘R can start a daemon
without a bundled runtime. If you already have one running — `bigbro serve` in a terminal — the app
finds and attaches to it rather than starting a second, and the override is never reached. Worth
exercising both ways, and worth knowing that quitting the app stops that daemon too.

Xcode signs development builds with your Apple Development identity and the real entitlements,
hardened runtime included. That matters beyond convenience: notifications need a genuine signature
and a stable bundle id, so pairing banners work in development rather than only in a signed
release — and an entitlement that would break under the hardened runtime breaks here, not during
notarization.

CI does not use any of this. It builds the package with SwiftPM and assembles the bundle with
`app/Scripts/make-app.sh`, so nothing in the Xcode project can break a release.

```sh
swift test --package-path app      # the same Swift tests CI runs
uv run --extra dev pytest          # and the Python side
```

## Usage

Open BigBro. The menu bar item is the day-to-day face of it: serving state at a glance, which
models are loaded, and Approve/Deny right there when a phone asks to pair — no window to go
hunting for. The window has the detail.

The app starts the daemon itself and stops it when you quit — including when it is force-quit or
crashes, which it cannot notice from the inside, so the daemon watches for the app disappearing and
shuts itself down. Nothing is left holding the Mac awake.

If a daemon is *already* running — you started one in a terminal, or put one behind launchd —
BigBro attaches to that one rather than starting a second, and says so in the menu. Quitting stops
that one too. There is only ever one daemon and one control socket, so the app and the CLI are
always talking about the same thing.

### From a terminal

```sh
bigbro serve                    # run the daemon
bigbro serve --port 9000        # listen somewhere else
bigbro serve --no-keep-awake    # let the Mac sleep normally while serving
bigbro shutdown                 # stop it, from anywhere
```

A daemon started from a terminal keeps serving until you stop it. `bigbro shutdown`
reaches it over the control socket, so you never have to go looking for a pid — which
matters because the daemon holds the Mac awake, and Ctrl-C only helps if you still
have the window that started it.

A daemon started by **BigBro.app** stops when the app does. Quitting sends it a stop;
being force-quit or crashing sends nothing at all, so the daemon also watches for the
process that started it disappearing (`--exit-with-parent`, passed on every spawn) and
shuts itself down within a couple of seconds. macOS has no `PR_SET_PDEATHSIG`, so
watching from the child is the only arrangement that survives a kill the parent never
saw coming.

Leave it running, or put it behind launchd. Every other command talks to the running daemon over a
Unix socket, so they work from any shell — including when the daemon has no terminal at all, and
including against a daemon BigBro.app started.

### The window

| Pane | What it does |
|---|---|
| **Devices** | Paired devices, each showing connected/offline and updating as they come and go, plus anything awaiting approval |
| **Text** / **Vision** / **TTS** / **STT** | One pane per model family, each listing real model names with capabilities, lifecycle state, a live download progress bar and memory held |
| **Settings** | Port, keep-awake and log level, written straight through to the daemon. Also installs the `bigbro` command line tool |
| **Log** | The daemon's log, streamed over the control socket — so it works against a daemon started anywhere, including under launchd |

Everything the window does, it does by sending the same control-socket commands the CLI sends.
Neither one can quietly diverge from the other, and ordering and wording come from the daemon
rather than being reproduced in two places.

### Downloads

Progress is pushed live — to the dashboard's Models pane and to every connected iOS device as
`modelDownloadProgress`. The size is taken from the Hub's file metadata before the transfer starts,
counting only the files that will actually be fetched, so the percentage means what it says.

BigBro fetches the same `allow_patterns` `mlx-lm` and `mlx-vlm` use, rather than the whole repo. A
model repository that also ships original PyTorch weights or a GGUF conversion would otherwise cost
gigabytes nothing ever reads — and would inflate the total past anything the download could reach.

### Memory

`bigbro status` and the dashboard both report what the daemon is holding:

```
  memory:      11.2 GB (weights) of 36.0 GB (31%)
    mlx:       11.2 GB active, 6 KB cached, 11.2 GB peak
    process:   11.5 GB footprint, 9.4 GB resident
    gpt-oss-20b          11.2 GB
```

**The headline is MLX's figure, not the process size**, because the process numbers are not
trustworthy for this. Measured across three loads of the same 12 GB model, resident size read
1.8 GB once and 11.8 GB on the others, and after unloading it still reported 10.6 GB while MLX
held 400 KB — the allocator had not handed the pages back. MLX said 11.2 GB every time. Weights
are what you are asking about when you ask what a model costs, and MLX is the only source that
answers consistently. With nothing loaded the process figure leads instead, since MLX reporting
zero would read as bigbro using no memory at all.

- **mlx** — `active` is what MLX is deliberately holding, `cache` is buffers kept between
  requests, `peak` is the high-water mark.
- **process** — `footprint` is what Activity Monitor shows; `resident` is the kernel's resident
  size. The gap between these and `active` is cache, activations, and pages not yet returned.
- **per-model** — measured, not taken from the catalog's approximate size, by reading MLX's
  allocation before and after each model's weights are materialized. Quantized weights vary between
  revisions, and what matters is what this Mac is holding right now. Loads are serialized so two
  models racing cannot be charged each other's weights.

macOS's own pressure verdict is appended when it stops being `normal` — reported rather than
derived from free pages, because with compression and a dynamic file cache "free" means very
little.

A stopped model drops out of the per-model list immediately — it is no longer being held.

### Keeping the Mac awake

The daemon holds an IOKit `PreventSystemSleep` assertion for its entire run — the same one
`caffeinate -s` takes — so the Mac stays available to paired devices instead of napping between
sessions. `bigbro status` shows whether it is held, and `pmset -g assertions` confirms it from
outside.

On AC power this keeps the Mac running even with the lid closed. On battery, macOS still enforces
clamshell sleep and overrides the assertion. Display sleep is always allowed. Pass
`--no-keep-awake` to skip it entirely.

### Pairing

An unknown device's `hello` **parks**: the connection is held open, unregistered, while the daemon
waits for a decision. With BigBro.app running that decision is a prompt and a click — from the menu
bar, so it reaches you even when nothing is focused. Headless, the daemon logs

```
WARNING  bigbro.pairing   'Cedric's iPhone' (MyApp) wants to pair — approve in the dashboard, or run: bigbro pair approve a1b2c3d4
```

and `bigbro pair approve` from any shell completes the handshake. A parked request is denied and closed after 5 minutes so an ignored one cannot hold a
socket open forever — the device can always reconnect and ask again.

Approval travels over a Unix socket at `~/Library/Application Support/bigbro/control.sock`, mode
`0600`. Nothing about pairing is reachable from the network the daemon advertises on.

## Models

BigBro can download and run any model in its catalog. **Every request names its own model.** There
is no default: BigBro answers with the model it was asked for or fails, so a client can never be
silently served by a different one.

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
[Capability mismatches](#capability-mismatches). Requests carrying images must name a vision model,
since a language model has no vision tower.

Any number of models can run at once; starting one never stops another. Nothing is ever stopped
automatically, so a Mac running several large models holds them all in memory until told
otherwise — see [Model lifecycle](#model-lifecycle).

Every MLX call — language, vision and speech alike — runs on one dedicated thread. MLX registers
its streams per-thread, so a model loaded on one thread and generated from another raises
`RuntimeError: There is no Stream(gpu, 1) in current thread`. That single thread also serializes
generation, which MLX needs anyway: two devices issuing overlapping requests queue rather than
corrupting each other's output.

## Speech

Text-to-speech (Kokoro) and speech-to-text (Parakeet v3) run in-process via `mlx-audio` — again, no
separate server. Each is a model in its own right, downloaded/run/stopped/removed from the CLI
exactly like a language or vision model; there is no "enable speech" switch. A speech model also
starts lazily the same way: the first `speechRequest`/`transcribeRequest` that needs it triggers
the load if it isn't already running.

Voice selection (which Kokoro speaker to use) is a BigBroKit parameter, not a Mac setting — see
`BigBroClient.defaultVoice`. The Mac has no configured default of its own.

Synthesized audio is always 24 kHz 16-bit mono PCM — the only format Kokoro produces, and what
BigBroKit's `BigBroAudioPlayer` expects.

It is forwarded as Kokoro produces it, not after the whole utterance is synthesized. Kokoro splits
long text into segments and finishes them in order, so each is chunked onto the wire as it lands:
for a 2,800-character answer the first audio arrives in 0.9 s while synthesis runs for another
4 s behind it. Short replies synthesize far faster than real time — 23 s of speech in 0.7 s — so
there the distinction does not matter.

Note that `streaming` on `request` / `generateRequest` is about *text*, and governs client-side
accumulation rather than what the Mac sends. Speech is a separate request and is always chunked.

Uploaded audio can be `wav`, headerless `pcm`, or any container CoreAudio reads — `m4a` above all,
since that is what `AVAudioRecorder` produces by default and therefore what an iOS app records
without being told otherwise. Anything compressed is decoded with `afconvert`, which ships with
macOS, rather than by adding a decoding dependency.

Audio is then resampled to whatever rate the transcription model expects, using the rate declared
in the WAV header. Parakeet is handed raw samples and applies its own configured rate to
them, so a 24 kHz utterance passed through untouched transcribes as though it were 16 kHz — faster
and higher, which comes back as plausible wrong words rather than an error. Headerless PCM is
assumed to be 24 kHz, the rate BigBroKit records at.

Kokoro phonemizes through `misaki`, which needs a spaCy model. Both are declared dependencies: left
optional, `misaki` raises at synthesis time and — worse — calls `sys.exit` when it cannot fetch the
model itself, which used to take the whole daemon down with it.

## Required models

iOS apps built with BigBroKit can declare which models they require. On connect, BigBro:

1. Reports missing models back to the iOS app in the `helloAck` response, resolved to the catalog entry each name refers to
2. Logs which models need downloading, with the command to pull them
3. Pushes live updates to connected devices as local models finish downloading

If an inference request arrives before the model it needs is downloaded, BigBro starts the download
and tells the client, rather than generating anything.

## TCP protocol

BigBro uses a custom framed TCP protocol on port 8765. Each message is a 4-byte big-endian length
prefix followed by a UTF-8 JSON object. **This is unchanged from BigBro's Ollama-proxy days and
unchanged by the move off Swift** — existing BigBroKit clients work against this daemon without a
rebuild.

### iOS → Mac messages

| Type | Fields | Description |
|---|---|---|
| `hello` | `deviceId`, `deviceName`, `appName`, `requiredModels?` | Initiate pairing |
| `request` | `requestId`, `messages`, `streaming`, `model`, `tools?`, `options?`, `think?`, `reasoning_effort?` | Chat request |
| `generateRequest` | `requestId`, `prompt`, `streaming`, `model`, `images?`, `system?`, `options?`, `think?`, `reasoning_effort?` | Single-turn generate |
| `speechRequest` | `requestId`, `input`, `voice?`, `speed?` | Text-to-speech |
| `transcribeRequest` | `requestId`, `audio` (base64), `audioFormat?` | Speech-to-text. `wav`, `pcm`, or any container CoreAudio reads — `m4a`, `mp3`, `aac`, `caf`, `aiff`, `flac`, `alac`. Max 10 MB decoded |
| `run` | `requestId`, `model` (a catalog id, or `"tts"` / `"stt"` / `"speech"`) | Starts a model — puts its weights in memory — without generating anything |
| `stop` | `requestId`, `model` (a catalog id) | Unloads a model from memory, keeping the download |
| `ping` | — | Keepalive; answered with `pong` |
| `bye` | — | Clean disconnect |

`model` names a catalog entry and is **required** — BigBro has no default to fall back on. A
request that names no model, or names one BigBro doesn't have, comes back as an `error` rather than
being answered by something else. A request carrying images must name a vision model for the same
reason: a language model has no vision tower, and with nothing configured to substitute, answering
from the text alone would be a silent wrong answer.

`format` (JSON-schema-constrained output) and `keep_alive` are accepted for wire compatibility but
currently have no effect — loaded models stay resident regardless of idle time.

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
| `modelDownloading` | `requestId`, `model`, `alreadyInProgress` | A request needed a model that isn't downloaded; the pull has started |
| `modelDownloadProgress` | `model`, `status`, `completed`, `total` | Broadcast during a download |
| `modelDownloadComplete` | `model`, `status`, `completed`, `total`, `success`, `error?` | Broadcast when one finishes |
| `modelsUpdate` | `missingModels` | Pushed when a local model finishes downloading |
| `pong` | — | Keepalive response |
| `bye` | — | Clean disconnect |

### Models

Any model in the catalog can be downloaded and run, and every request picks one by name. The
catalog is curated rather than derived, because each entry carries three hand-verified facts that
cannot be inferred — and a wrong value corrupts responses rather than failing:

| Fact | Why it can't be guessed |
|---|---|
| Tool support | Whether the chat template has a tools slot at all. Gemma and Phi don't. |
| Reasoning style | None (Gemma, Llama), harmony channels (gpt-oss), or `<think>` tags (Qwen3, DeepSeek-R1). |
| Effort control | `reasoning_effort` is harmony-only; Qwen3's lever is `enable_thinking`, a different key. |

Adding a model means adding an entry in `src/bigbro/inference/catalog.py` and checking those three
fields. `bigbro models check` verifies the repo id resolves; the three facts still need a human.

### Capability mismatches

A request can ask for more than the chosen model can do. Where the model can still answer usefully,
BigBro adapts and says what it dropped — refusing would be worse:

- **Tools** on a model without them are removed before templating. Passing them anyway either
  throws in the template or drops them silently, and neither tells the caller anything.
- **`reasoning_effort`** on a non-harmony model is dropped. Jinja ignores unknown variables, so
  left in it would look like it worked while doing nothing.

**Images** on a language model are the exception: that one fails. The image never reaches the
prompt at all, so there is no useful answer to adapt down to — only an answer from the text alone,
which reads as if the model looked.

Each of these sends a `modelCapabilities` message before the answer, carrying the model's real
capabilities and a human-readable note per adaptation. BigBroKit exposes it as `client.modelNotes`.
Clients that predate the message ignore it. Only a setting the client *explicitly sent* is ever
reported as dropped — the `low` that `think: false` implies is BigBro's own inference, not a
request that was degraded.

Output framing is chosen per model too. The harmony parser withholds text until it sees channel
markers, so running it over a Gemma response would swallow the opening of every reply — each
reasoning style gets its own parser (`inference/parsers.py`).

### Reasoning: `think` vs `reasoning_effort`

Two separate knobs, and the difference matters:

| Field | What it changes | Where it acts |
|---|---|---|
| `think` (default on) | Whether reasoning tokens are sent to the client as `thinking` messages | After generation — pure wire filtering in the router |
| `reasoning_effort` | How long the model spends in its `analysis` channel before reaching the final one | Before generation — passed to the chat template |

gpt-oss computes its harmony `analysis` channel either way, so `think` alone changes what the
client sees, not what the model does or how long it takes. `reasoning_effort` is the one that
actually shortens the work.

Valid values are **`low`, `medium`, `high`** — nothing else. The Harmony template renders the value
literally into the system message as `Reasoning: <level>`, and gpt-oss was trained on exactly those
three words, so there is no "off": a fourth value would land in the prompt as text the model has
never seen, degrading the answer rather than skipping the analysis. `low` is as close to off as
gpt-oss gets. Unrecognized values are dropped and the template default (`medium`) applies.

When `reasoning_effort` is absent, `think: false` is read as a request for speed and lowers the
budget to `low` — preserving what that flag did on its own before clients could name a level. An
explicit `reasoning_effort` always wins over that inference.

### Model lifecycle

Downloaded and running are different states, and BigBro treats them separately because they cost
different things: weights on disk cost only disk, weights in memory cost RAM — 12 GB of it for
gpt-oss-20b. A model can sit downloaded indefinitely at no cost until something needs it.

| Operation | Effect | Where |
|---|---|---|
| **Download** | Fetches weights to disk. Does not use memory. | `bigbro models download`, or automatically when a request needs a model that isn't there |
| **Start** | Materializes weights into memory so the model can answer | `bigbro models start`, the `run` wire message, or automatically on first request |
| **Stop** | Frees the memory, keeps the download | `bigbro models stop`, or the `stop` wire message |
| **Delete** | Deletes the weights from disk | `bigbro models delete` only |

Removal is deliberately not on the wire. It is destructive and irreversible over a slow download,
so it belongs to whoever owns the Mac rather than to any paired device. Stopping is fine to
expose — the download survives, so the worst case is a slow next request — but note that models are
shared by every paired device, so one device stopping a model takes it away from all of them.

Deleting means deleting the Hugging Face **repository** directory, not just the snapshot. The cache
stores a model's bytes once and names them twice: data in `<repo>/blobs/<etag>`, and
`<repo>/snapshots/<commit>/` as a tree of symlinks into it. Deleting only the snapshot reclaims
nothing. BigBro never guesses at that layout — it walks up from the path the downloader itself
reported, and only when that path is positively identifiable as a snapshot inside a repo.

#### Starting a model ahead of time

Starting a model is a real multi-second cost that BigBro otherwise pays lazily, on whichever
message happens to be first. Send `run` when a session is likely to start soon (e.g. when the chat
screen appears) to move it earlier instead:

- If the model is downloaded, BigBro loads it and replies `done` once it can answer — nothing is generated.
- If it isn't downloaded, this triggers the same `modelDownloading` flow a real request would.

BigBroKit exposes this as `BigBroClient.runModel(_:)` and `stopModel(_:)`. Both are pure
optimizations — skipping `run` is harmless, since a request starts the model it needs anyway.
`preload` is still accepted as an alias for `run`, so clients built before the rename keep working.

`"tts"`, `"stt"` and `"speech"` (both) start Kokoro and Parakeet instead, via
`BigBroClient.runSpeech()`. Like a language model, BigBro loads these lazily on whichever request
needs them first — `run` just gives a client somewhere to *wait* ahead of that. That matters for a
hands-free voice loop, where a cold model load would otherwise swallow the first thing the user
says. There is no matching stop from a client: speech models are shared and reload slowly, so
letting one client evict them for everyone isn't a trade worth offering. Whoever owns the Mac can
still stop or remove them locally.

### Spoken conversation

There is no server-side voice mode: an end-to-end spoken turn is `transcribeRequest` → `request` →
`speechRequest`, driven from the client. That is deliberate — the tool-calling loop runs on the
device, so only the client knows which model turn is a final answer worth speaking and which is an
intermediate tool step. BigBroKit packages the sequence as `BigBroClient.converse(audio:)` and the
continuous version as `BigBroVoiceSession`.

## Development

```sh
git clone https://github.com/cedricnagata/bigbro
cd bigbro
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"
pytest
```

The venv is not optional housekeeping — without one, `uv pip install -e` targets whatever Python is
active and upgrades the shared `transformers`/`huggingface-hub`/`pydantic` stack system-wide.

The test suite covers everything that does not need Apple silicon — the response parsers, the
catalog invariants, the wire codec, the pairing state machine, the control socket, and a full
end-to-end pass over a real socket with stub engines. Those run anywhere. Actual inference, Bonjour
registration and the power assertion need a Mac.

## State on disk

Everything lives in `~/Library/Application Support/bigbro/` (override with `BIGBRO_HOME`):

| File | Contents |
|---|---|
| `devices.json` | Approved device ids, names and app names |
| `downloads.json` | Catalog id → the directory its weights landed in |
| `config.json` | Port, keep-awake and log level. CLI flags override it |
| `control.sock` | The Unix socket the CLI and BigBro.app talk to, mode `0600` |

Model weights themselves live in the standard Hugging Face cache (`~/.cache/huggingface/hub`).

## Source layout

```
src/bigbro/
├── __main__.py             — the `bigbro` CLI
├── daemon.py               — wiring, lifecycle, control-command handlers
├── router.py               — message dispatch, capability negotiation, wire forwarding
├── control.py              — Unix control socket: commands + the event stream
├── events.py               — event fan-out to attached clients
├── config.py               — support directory, atomic JSON store
├── speech.py               — Kokoro TTS + Parakeet STT via mlx-audio
├── macos/
│   ├── bonjour.py          — DNSServiceRegister via ctypes (_bigbro._tcp.)
│   ├── memory.py           — process/system memory via mach task_info and sysctl
│   └── power.py            — IOPMAssertionCreateWithName via ctypes
├── protocol/
│   ├── framing.py          — the 4-byte length prefix codec
│   ├── server.py           — asyncio TCP server, peer registry
│   └── pairing.py          — approval queue, device persistence
└── inference/
    ├── catalog.py          — the supported models and their hand-verified capabilities
    ├── parsers.py          — per-model output framing: harmony channels, <think> tags, or plain
    ├── engine.py           — mlx-lm/mlx-vlm lifecycle, templating, generation
    ├── mlx_thread.py       — the one thread every MLX call runs on
    └── downloader.py       — Hub downloads with throttled progress
```

`mlx_thread.py` is load-bearing rather than an optimization. MLX registers its streams per-thread,
so a model loaded on one thread and generated from another raises `RuntimeError: There is no
Stream(gpu, 1) in current thread`. Anything that calls into MLX — language, vision, Kokoro,
Parakeet — goes through it.
