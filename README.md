# FreeFlow, fully local

Runs [FreeFlow](https://github.com/zachlatta/freeflow) dictation with no cloud API — speech
recognition and text cleanup both happen on your Mac. One script sets everything up and
registers it to start at login.

## Install FreeFlow first

This script configures an existing FreeFlow installation — it doesn't install the app itself.
Download it from the [FreeFlow repo](https://github.com/zachlatta/freeflow)
([latest release](https://github.com/zachlatta/freeflow/releases/latest)) and move
**FreeFlow.app into `/Applications`** *before* running the script.

If FreeFlow isn't there, the script still installs and starts both servers, but it skips the
app configuration step and prints a warning — you'd then have to enter the URLs and model
names by hand (see [Settings the script applies](#settings-the-script-applies)). Installing
FreeFlow afterward and re-running the script picks it up and configures it automatically.

## Setup

```bash
git clone git@github.com:wontonsoup99/local-freeflow-helper.git
cd local-freeflow-helper
./setup.sh
```

Takes ~10 minutes the first time (about 3 GB of model downloads). Safe to re-run.

## Requirements

- Apple Silicon Mac (M1 or newer), macOS 15+
- Native ARM Homebrew at `/opt/homebrew`
- [FreeFlow.app](https://github.com/zachlatta/freeflow) already in `/Applications` (see above)
- ~2–4 GB of RAM free while dictating (depends on cleanup model), ~4 GB of disk

## What you get

| | |
|---|---|
| **Speech-to-text** | Parakeet TDT v3 (CoreML, runs on the Neural Engine) via [`speech-server`](https://github.com/soniqo/speech-swift) |
| **Cleanup / edit mode** | Qwen3 4B Instruct via Ollama — [swappable](#choosing-a-cleanup-model) for smaller models |
| **Latency** | ~0.15 s transcription + ~0.7 s cleanup on an M3 Pro |
| **Memory** | ~4 GB resident with both models loaded (~2.2 GB on the `light` tier) |

Both models are preloaded at login, so the first dictation of the day is as fast as the
hundredth. Nothing leaves your machine.

## What the script changes

- Installs the `speech` and `ollama` Homebrew formulae
- Pulls the cleanup model (default `qwen3:4b-instruct-2507-q4_K_M`, ~2.5 GB — see
  [Choosing a cleanup model](#choosing-a-cleanup-model))
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
| Post-processing model + fallback | `qwen3:4b-instruct-2507-q4_K_M` (or your `--model` choice) |
| Context model | `qwen3:4b-instruct-2507-q4_K_M` (or your `--model` choice) |
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

## Choosing a cleanup model

The cleanup model is the RAM-hungry half of the stack, so it's the knob worth turning if
you're tight on memory. Pick a tier at install time:

```bash
./setup.sh --model light      # or: balanced, quality (default)
./setup.sh --list-models      # show this table in the terminal
```

| Tier | Model | RAM | Median latency | What you give up |
|---|---|---|---|---|
| `quality` *(default)* | `qwen3:4b-instruct-2507-q4_K_M` | 2.9 GB | 0.43 s | — |
| `balanced` | `granite4:3b` | 2.3 GB | 0.40 s | Rougher on non-English text |
| `light` | `qwen2.5:1.5b` | 1.1 GB | 0.24 s | No list formatting; **may answer a dictated question instead of transcribing it** |

You can pass any Ollama tag directly too: `./setup.sh --model llama3.2:3b`.

**The `light` caveat is worth understanding.** Dictating "what time does the standup start
tomorrow" into `qwen2.5:1.5b` produced *"The standup starts at 10:30 AM tomorrow."* — it
answered the question instead of typing it. `quality` and `balanced` both echo it correctly.
If you dictate questions, stay on 2 GB+.

### How these were chosen

Each candidate was scored on 15 test cases built from FreeFlow's own system prompt — filler
removal, cross-language self-corrections ("Thursday, no actually Wednesday"), list
formatting, identifier preservation (`user_id`), and the prompt's strictest rule: *echo
instructions, never execute them*. RAM is the measured resident size from
`/api/ps`, not the download size.

Results that shaped the table:

- **Smaller is not monotonically worse.** `qwen2.5:1.5b` (1.1 GB) outscored `qwen2.5:3b`
  (2.1 GB), which wrote an actual poem when asked to transcribe "make a poem about the moon."
- **Everything below ~1 GB failed.** `gemma3:270m` and `granite4:350m-h` scored 0/7 —
  they returned empty strings or ignored the prompt entirely. There is no usable sub-1 GB tier.
- **`granite4:1b` uses more RAM than `granite4:3b`** (3.5 GB vs 2.3 GB) because its default
  Ollama tag ships **BF16**, unquantized. The quantized `granite4:1b-h` fits in 1.7 GB but is
  3× slower and scored worse. Skip the 1b line entirely.
- **No model at this size respects "do not translate."** All of them turned
  "je suis en retard pour la réunion" into English. If you dictate in a non-English language,
  test before relying on it.

### Avoid reasoning models

`qwen3:1.7b`, plain `qwen3:4b`, `deepseek-r1`, and similar emit `<think>` blocks.
FreeFlow strips those for exactly two hardcoded cloud model names
([`ModelConfiguration.swift`](https://github.com/zachlatta/freeflow/blob/main/Sources/ModelConfiguration.swift));
every other model falls through with stripping disabled, so the reasoning gets typed into
your text field. Stick to `-instruct` builds. The script warns if you pick a known one.

## Transcription models

`speech-server` accepts these names in FreeFlow's transcription model field: `parakeet`
(default, fastest, 25 languages), `qwen3-asr`, `nemotron`, `omnilingual` (1,672 languages),
`parakeet-streaming`. Unknown names silently fall back to `parakeet`.
