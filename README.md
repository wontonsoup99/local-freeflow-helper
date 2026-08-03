# FreeFlow, fully local

Runs [FreeFlow](https://github.com/zachlatta/freeflow) dictation with no cloud API — speech
recognition and text cleanup both happen on your Mac. One script sets everything up and
registers it to start at login.

```bash
git clone <this-repo> freeflow-local-setup
cd freeflow-local-setup
./setup.sh
```

Takes ~10 minutes the first time (about 3 GB of model downloads). Safe to re-run.

## Requirements

- Apple Silicon Mac (M1 or newer), macOS 15+
- Native ARM Homebrew at `/opt/homebrew`
- [FreeFlow.app](https://github.com/zachlatta/freeflow/releases/latest) in `/Applications`
- ~4 GB of RAM free while dictating, ~4 GB of disk for models

## What you get

| | |
|---|---|
| **Speech-to-text** | Parakeet TDT v3 (CoreML, runs on the Neural Engine) via [`speech-server`](https://github.com/soniqo/speech-swift) |
| **Cleanup / edit mode** | Qwen3 4B Instruct (q4_K_M) via Ollama |
| **Latency** | ~0.15 s transcription + ~0.7 s cleanup on an M3 Pro |
| **Memory** | ~4 GB resident with both models loaded |

Both models are preloaded at login, so the first dictation of the day is as fast as the
hundredth. Nothing leaves your machine.

## What the script changes

- Installs the `speech` and `ollama` Homebrew formulae
- Pulls the `qwen3:4b-instruct-2507-q4_K_M` model (~2.5 GB)
- Writes `~/.local/bin/speech-server-launch.sh` and
  `~/Library/LaunchAgents/audio.soniqo.speech-server.plist` (starts at login, restarts on crash)
- Adds `OLLAMA_KEEP_ALIVE=24h` and `OLLAMA_FLASH_ATTENTION=1` to Ollama's launch agent
- Points FreeFlow at both servers by editing
  `~/Library/Application Support/FreeFlow/.settings` and its `defaults` domain

`./setup.sh --uninstall` reverses the launch agent and helper files (models and Homebrew
packages stay).

## First run of FreeFlow

The script configures FreeFlow, but macOS permissions can't be scripted. Open FreeFlow and:

1. Grant **Microphone** and **Accessibility** access when prompted
2. If it asks for an API key, type `local` — it validates against your local Ollama and passes
3. Hold `Fn` and talk

## Settings the script applies

If you'd rather set these by hand in FreeFlow → Settings:

| Setting | Value |
|---|---|
| API Base URL | `http://127.0.0.1:11434/v1` |
| API Key | `local` |
| Post-processing model + fallback | `qwen3:4b-instruct-2507-q4_K_M` |
| Context model | `qwen3:4b-instruct-2507-q4_K_M` |
| Transcription API URL | `http://127.0.0.1:8123/v1` |
| Transcription model | `parakeet` |
| Stream audio while recording | **off** (see below) |

## Why streaming is off

FreeFlow's realtime toggle opens an OpenAI Realtime WebSocket. `speech-server` accepts that
protocol but has two problems with it:

1. It rejects the upgrade because FreeFlow appends `?intent=transcription` and the server
   compares the raw path including the query string — `/v1/realtime` returns `101`,
   `/v1/realtime?intent=transcription` returns `400`.
2. It only transcribes on `input_audio_buffer.commit` and never emits transcript deltas, so
   there'd be no mid-sentence text even if it connected.

FreeFlow falls back to the batch endpoint automatically and that path is ~0.15 s, so leaving
the toggle off costs nothing and avoids a pointless failed connection each time.

## Troubleshooting

**"Endpoint not found … (HTTP 404)"** — something else owns the ASR port. Docker containers
love 8080. The script auto-picks a free port; re-run it, then check the Transcription API URL
in Settings matches.

**Dictation suddenly slow (~7 s)** — the LLM unloaded. Usually because someone ran
`brew services restart ollama`, which regenerates the launch agent and drops
`OLLAMA_KEEP_ALIVE`. Re-run `./setup.sh`. Restart Ollama with
`launchctl kickstart -k gui/$UID/homebrew.mxcl.ollama` instead.

**Transcription stops working entirely** — check `/tmp/speech-server.log`. The server aborts
if a WebSocket client disconnects without a close handshake; the launch agent restarts it
within ~10 s, so this should self-heal.

**Check everything is up:**

```bash
curl -s http://127.0.0.1:8123/health          # {"status":"ok"}
curl -s http://127.0.0.1:11434/api/ps         # should list the qwen3 model
```

## Other models

`speech-server` accepts these transcription model names — swap in FreeFlow's transcription
model field: `parakeet` (default, fastest, 25 languages), `qwen3-asr`, `nemotron`,
`omnilingual` (1,672 languages), `parakeet-streaming`. Unknown names silently fall back to
`parakeet`.

For cleanup, any Ollama chat model works. Avoid reasoning models (plain `qwen3:4b`,
`deepseek-r1`) — FreeFlow only strips `<think>` tags for a couple of hardcoded model names,
so reasoning output would land in your text field. Stick to `-instruct` builds.
